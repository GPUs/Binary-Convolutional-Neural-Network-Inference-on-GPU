#include <iostream>
#include <stdlib.h>
#include <fstream>
#include <sstream>
#include <utility>
#include <unordered_map>
#include <cuda.h>
#include <cuda_runtime.h>
#include <device_launch_parameters.h>
#include <chrono>
#include <vector>
#include <assert.h>
#include <math.h>

#define NUM_STREAMS 16



// This is first version of the gpu implementation
// This version is just for testing sub-parts of the xnor convolution
constexpr std::pair<int, int> register_size(8, 4);
constexpr int nTPB = 256;

template <typename T>
struct matrix1d {
	int lenght;
	T *arr;
};

template <typename T>
struct matrix2d {
	int row;
	int col;
	T *arr;
};

template <typename T>
struct matrix3d {
	int row;
	int col;
	int channel;
	T **arr;
};

template <typename T>
struct weight4d{
	int row;
	int col;
	int channel_in;
	int channel_out;
	T **arr;
};


#define gpuErrchk(ans) { gpuAssert((ans), __FILE__, __LINE__); }
inline void gpuAssert(cudaError_t code, const char *file, int line, bool abort=true)
{
   if (code != cudaSuccess)
   {
      fprintf(stderr,"GPUassert: %s %s %d\n", cudaGetErrorString(code), file, line);
      if (abort) exit(code);
   }
}

std::pair<int, int> find_binary_size(std::pair<int, int>input_size,  std::pair<int, int>kernel_size){
	int size_x = ceil((input_size.first - register_size.first)
						/static_cast<double>(register_size.first + 1 - kernel_size.first) + 1);
	int size_y = ceil((input_size.second - register_size.second )
						/static_cast<double>(register_size.second + 1 - kernel_size.second) + 1);
	if (size_x < 0)
		size_x = 1;
	if (size_y < 0)
		size_y = 1;
	return std::make_pair(size_x, size_y);
}

size_t choose_block_size(size_t val){
  if (val >= nTPB) return nTPB;
  if (val <= 32) return 32;
  val = (val >> 1) | val;
  val = (val >> 2) | val;
  val = (val >> 4) | val;
  val = (val >> 8) | val;
  val = (val >> 16) | val;
  val++;
  return val;
}

template<typename T>
void __global__ zeroPadding(matrix2d<T> *input_mat, matrix2d<T>* output_mat,  int kernel_row, int kernel_col)
{
	int idx = threadIdx.x + blockDim.x * blockIdx.x;
	int index_x = (idx % output_mat->col) - (kernel_col - 1)/ 2;
	int index_y = (idx/ output_mat->col) - (kernel_row - 1)/ 2;
	if(index_x > 0 || index_y>0 )
	{
		if( index_x< input_mat->col || index_y < input_mat->row)
		{
			output_mat[idx] = input_mat[index_y * output_mat->col + index_x];
		}
	}
	else output_mat[idx] = 0;
}
template<typename T>
void __global__ zeroPadding(T * input_mat, T * output_mat,  int kernel_row, int kernel_col, int input_row, int input_col, int output_row, int output_col)
{
	int idx = threadIdx.x + blockDim.x * blockIdx.x;
	int index_x = (idx % output_col) - (kernel_row - 1)/ 2;
	int index_y = (idx/output_col) - (kernel_col - 1)/ 2;
	if (idx < output_row * output_col)
	{
		if(index_x > 0 && index_y>0 )
		{
			if( index_x< input_col && index_y < input_row)
			{
				output_mat[idx] = input_mat[index_y * input_col + index_x];
			}
		}
		else output_mat[idx] = 0;
	}
}

template<typename T>
 __device__ void to_binary_register(
	const T &idata,
	unsigned int &odata,
	 int *output_location)
{
	int sign = (idata > 0) - (idata < 0);
	const unsigned int pozitive = 1;
	const unsigned int negative = 0;
	//int count = output_location[1] * register_size.second  + output_location[0];
	//assert(count < register_size.second * register_size.first);
	if (sign > -1)
	{
		odata = pozitive<<(output_location[1] * register_size.first  + output_location[0]) | odata;
	}
	else
	{
		odata = negative<<(output_location[1] * register_size.first  + output_location[0]) | odata;
	}
}

template<typename T>
void __global__  to_binary_matrix(
	const T *  d_idata,
	unsigned int *  d_odata,
	const int row, const int b_row,
	const int col, const int b_col,
	const int kernel_row = 3, const int kernel_col = 3)
{
	// Each thread will store a size = 32 array inside their single register
	int idx = threadIdx.x+blockDim.x*blockIdx.x; //register IDX
	// n*(regsiter_size - kernel_size)
	if (idx < (b_row * b_col))
	{
		int input_index[] = {(idx%b_col) * (register_size.first - kernel_col), (idx /b_col ) * (register_size.second - kernel_row)};
		int data_idx = input_index[0] + (input_index[1] * row);
		//int input_index[] = {data_idx%row, data_idx/col, data_idx/(row*col)}; // from start of array , (x, y, z)
		int register_location[] = {0, 0};
		unsigned int local_register;
		for (int j=0; register_size.second>j; j++)
		{
			for (int i=0; register_size.first>i; i++)
			{
				to_binary_register<T>(d_idata[data_idx], local_register, register_location);
				++data_idx;
				input_index[0] += 1;
				register_location[0] += 1;
				if (input_index[0] == col) break;
			}
			data_idx = data_idx + col - register_location[0];
			input_index[1] += 1;
			input_index[0] = (idx%b_col) * (register_size.first - kernel_col);
			register_location[0] = 0;
			register_location[1] += 1;
			if (input_index[1] == row) break;
		}
		d_odata[idx] = local_register;
	}
}
void __global__ binaryConv2d(
		const unsigned int * binary_mat,
		unsigned int * output_mat,
		const unsigned int *weight_matrix,
		int binary_row, int binary_col,
		int kernel_row, int kernel_col,
		int output_row, int output_col
		)
{

	int idx = threadIdx.x +blockDim.x*blockIdx.x; //binary Cell id
	int conv_per_row = register_size.second - (kernel_row - 1);
	int conv_per_column = register_size.first - (kernel_col - 1);
	int output_index_x = (idx % binary_col) * conv_per_column;
	int output_index_y = (idx / binary_col) * conv_per_row;
	//return;
	if (idx < binary_row * binary_col)
	{
	unsigned int register_buffer = binary_mat[idx];
	if ( (output_index_x + conv_per_column) > output_col)
	{
		conv_per_column = output_col - output_index_x;
	}
	if ( (output_index_y + conv_per_row) > output_row)
	{
		conv_per_row = output_row - output_index_y;
	}

	unsigned int mask = std::pow(2, kernel_col) - 1;

	for (int j=1; kernel_row > j; j++)
	{
		mask = (mask<<register_size.first) | static_cast<unsigned int>(std::pow(2, kernel_col) - 1);
	}

	unsigned int shifter = 0;
	for (int j=0; conv_per_row>j; ++j)
	{
		for (int i=0; conv_per_column>i; ++i)
		{

			output_mat[(output_index_y+j)*output_col + output_index_x + i] = (~(register_buffer>>shifter) ^ (weight_matrix[0]) ) & mask;
			++shifter;
		}
		// Check if register is not fully filled,
		// if not add shifter the missing shift amount
		shifter += register_size.second - conv_per_column;
	}
	}

}

void __global__ binary2int(unsigned int *input_mat, int matrix_row, int matrix_col, int kernel_row, int kernel_col)
{
	int idx = threadIdx.x + blockDim.x * blockIdx.x;
	if (idx < matrix_row* matrix_col)
	{
		unsigned int mask = 1;
		unsigned int shifter = 0;
		int buffer = 0;
		unsigned int data = input_mat[idx];
		for (int j=0; kernel_row>j; ++j)
		{
			for(int i=0; kernel_col>i; ++i)
			{
				buffer += (data >> shifter) & mask;
				++shifter;
			}
			shifter += register_size.first - kernel_col;
		}
		input_mat[idx] = 2 * buffer - (kernel_row * kernel_col);
	}
}

void __global__ kernel_reduce_sum(
		const unsigned int * __restrict__  d_idata,
		float * __restrict__ d_odata,
        const int col,
        const int row,
        const int channel)
{
	int idx = threadIdx.x+blockDim.x*blockIdx.x;
	if (idx < (col * row)){
	  int tidx = idx;
	  float tsum = 0;
	  for (int i = 0; i < channel; i++)
	  {
		tsum += static_cast<float>(d_idata[tidx]);
		tidx += row * col;
	  }
	  d_odata[idx] = tsum / static_cast<float>(channel);
	}
}
// A single Xnor convolution,
// Inputs are input float matrix and weight tensor;  output as float output matrix
// There are two main part in Xnor convolution that can be done in concurrently
// Finding K matrix, and binary xnor convolution.
// Then convolution Result and K matrix can multiply in elementwise,
// Final result will be obtained by multiplying by alpha scalar.

matrix2d<unsigned int> floatMat2BinaryMat(matrix2d<float> &d_input_matrix, int kernel_col, int kernel_row, cudaStream_t streamID = 0)
{
	cudaStreamCreate ( &streamID) ;
	matrix2d<unsigned int> d_output_matrix;
	auto binary_size = find_binary_size(std::make_pair(d_input_matrix.col, d_input_matrix.row), std::make_pair(kernel_col, kernel_row));
	cudaMalloc(&d_output_matrix.arr, binary_size.first * binary_size.second *sizeof(unsigned int));
	auto block_size = choose_block_size(binary_size.first * binary_size.second);
	d_output_matrix.col = binary_size.first;
	d_output_matrix.row = binary_size.second;
	to_binary_matrix<<<(d_output_matrix.row * d_output_matrix.col + block_size - 1)/ block_size , block_size, 0, streamID>>>
			(d_input_matrix.arr, d_output_matrix.arr, d_input_matrix.row, d_output_matrix.row, d_input_matrix.col, d_output_matrix.col);
	return d_output_matrix;
}




matrix3d<float> xnor_convolution_v1(matrix3d<float> &h_input_tensor, weight4d<float> &h_weight_tensor, bool padding=true)
{
		// Use cudaMallocHost
		//cudaStream_t streams[NUM_STREAMS];
		//for (int i = 0; i < NUM_STREAMS; ++i) { cudaStreamCreate(&streams[i]); }

	matrix3d<float> h_output_tensor;
	h_output_tensor.col = h_input_tensor.col;
	h_output_tensor.row = h_input_tensor.row;
	h_output_tensor.channel = h_weight_tensor.channel_out;
	h_output_tensor.arr = new float *[h_output_tensor.channel]();
	for(int i=0; h_output_tensor.channel > i; ++i)
	{
		h_output_tensor.arr[i] = new float [h_output_tensor.row * h_output_tensor.col];
	}


	for (int j=0; j < h_weight_tensor.channel_out; ++j )
	{
		unsigned int **h_channel_outputs = new unsigned int*[h_weight_tensor.channel_in]();
		for (int i=0; i<h_weight_tensor.channel_in; ++i)
		{
			h_channel_outputs[i] = new unsigned int[h_input_tensor.row * h_input_tensor.row];
		}
		for (int i=0; i< h_weight_tensor.channel_in; ++i)
		{
			cudaEvent_t start, stop;
			cudaEvent_t start1, stop1;
			cudaEvent_t start2, stop2;
			cudaEvent_t start3, stop3;
			cudaEventCreate(&start2);
			cudaEventCreate(&stop2);
			cudaEventCreate(&start);
			cudaEventCreate(&stop);
			cudaEventCreate(&start1);
			cudaEventCreate(&stop1);
			cudaEventCreate(&start3);
			cudaEventCreate(&stop3);
			float milliseconds = 0;
			matrix2d<float> d_input_matrix;
			d_input_matrix.col = h_input_tensor.col;
			d_input_matrix.row = h_input_tensor.row;
			cudaMalloc((void **)&d_input_matrix.arr, sizeof(float) * d_input_matrix.col* d_input_matrix.row);
			cudaMemcpy(d_input_matrix.arr, h_input_tensor.arr[i], d_input_matrix.col* d_input_matrix.row * sizeof(float), cudaMemcpyHostToDevice);
			matrix2d<float> d_weight_matrix;
			d_weight_matrix.col = h_weight_tensor.col;
			d_weight_matrix.row = h_weight_tensor.row;
			cudaMalloc((void **)&d_weight_matrix.arr, sizeof(float) * d_weight_matrix.col * d_weight_matrix.row);
			cudaMemcpy(d_weight_matrix.arr, h_weight_tensor.arr[j*h_weight_tensor.channel_in + i], sizeof(float) * d_weight_matrix.col * d_weight_matrix.row, cudaMemcpyHostToDevice);

			matrix2d<float> d_padded_matrix;
			d_padded_matrix.col = d_input_matrix.col + h_weight_tensor.col - 1;
			d_padded_matrix.row = d_input_matrix.row + h_weight_tensor.row - 1;
			cudaMalloc((void **)&d_padded_matrix.arr, d_padded_matrix.col * d_padded_matrix.row * sizeof(float));
			auto block_size = choose_block_size(d_padded_matrix.row * d_padded_matrix.col);
			cudaEventRecord(start3, 0);
			zeroPadding<float><<<(d_padded_matrix.row * d_padded_matrix.col + block_size - 1)/ block_size , block_size>>>(d_padded_matrix.arr, d_padded_matrix.arr, h_weight_tensor.row, h_weight_tensor.col, d_input_matrix.row, d_input_matrix.col, d_padded_matrix.row, d_padded_matrix.col);
			cudaEventRecord(stop3, 0);
			cudaEventSynchronize(stop3);
			cudaEventElapsedTime(&milliseconds, start3, stop3);
			std::cout<<"ZeroPadding Time= "<< milliseconds<<std::endl;
			cudaFree(d_input_matrix.arr);
			cudaEventRecord(start, 0);
			auto d_binary_input_matrix = floatMat2BinaryMat(d_padded_matrix, h_weight_tensor.row, h_weight_tensor.col);
			cudaEventRecord(stop, 0);
			cudaEventSynchronize(stop);
			cudaEventElapsedTime(&milliseconds, start, stop);
			std::cout<<"Integer to binary conversion Time= "<< milliseconds<<std::endl;
			cudaFree(d_padded_matrix.arr);
			auto d_binary_weight_matrix = floatMat2BinaryMat(d_weight_matrix, h_weight_tensor.row, h_weight_tensor.col);
			cudaFree(d_weight_matrix.arr);
			block_size = choose_block_size(d_binary_input_matrix.col * d_binary_input_matrix.row);
			matrix2d<unsigned int> d_binary_output_matrix;
			d_binary_output_matrix.col = h_input_tensor.col;
			d_binary_output_matrix.row = h_input_tensor.row;
			cudaMalloc((void **)&d_binary_output_matrix.arr, d_binary_output_matrix.col * d_binary_output_matrix.row * sizeof(float));
			cudaEventRecord(start1, 0);
			binaryConv2d<<<(d_binary_input_matrix.row * d_binary_input_matrix.col + block_size - 1)/ block_size ,block_size>>>(d_binary_input_matrix.arr, d_binary_output_matrix.arr, d_binary_weight_matrix.arr,
																												d_binary_input_matrix.row, d_binary_input_matrix.col,
																												d_weight_matrix.row, d_weight_matrix.col,
																												d_binary_output_matrix.row, d_binary_output_matrix.col);
			cudaEventRecord(stop1, 0);
			cudaEventSynchronize(stop1);
			cudaEventElapsedTime(&milliseconds, start1, stop1);
			std::cout<<"Convolution Time= "<< milliseconds<<std::endl;
			block_size = choose_block_size(d_binary_output_matrix.col * d_binary_output_matrix.row);
			cudaEventRecord(start2, 0);
			binary2int<<<(d_binary_output_matrix.row * d_binary_output_matrix.col + block_size - 1)/ block_size ,block_size>>>(d_binary_output_matrix.arr, d_binary_output_matrix.row, d_binary_output_matrix.col, d_weight_matrix.row, d_weight_matrix.col);
			cudaEventRecord(stop2, 0);
			cudaEventSynchronize(stop2);
			cudaEventElapsedTime(&milliseconds, start2, stop2);
			std::cout<<"Binary to integer conversion Time= "<< milliseconds<<std::endl;
			cudaMemcpy(h_channel_outputs[i], d_binary_output_matrix.arr, sizeof(unsigned int) * d_binary_output_matrix.row * d_binary_output_matrix.col, cudaMemcpyDeviceToHost);
			cudaFree(d_binary_output_matrix.arr);
			cudaEventDestroy(start);
			cudaEventDestroy(stop);
			cudaEventDestroy(start1);
			cudaEventDestroy(stop1);
			cudaEventDestroy(start2);
			cudaEventDestroy(stop2);
		}
		matrix2d<float> d_output_matrix;
		d_output_matrix.col = h_output_tensor.col;
		d_output_matrix.row = h_output_tensor.row;
		auto block_size = choose_block_size(d_output_matrix.col * d_output_matrix.row);
		unsigned int *buffer = new unsigned int[h_output_tensor.col * h_output_tensor.row * h_weight_tensor.channel_in];
		memcpy(buffer, h_channel_outputs, sizeof(h_channel_outputs));
		unsigned int *d_channel_outputs;
		cudaMalloc((void**)&d_channel_outputs, sizeof(unsigned int) * h_output_tensor.row * h_output_tensor.col * h_weight_tensor.channel_in);
		cudaMalloc((void **)&d_output_matrix.arr, sizeof(float) * h_output_tensor.row * h_output_tensor.col);
		cudaMemcpy(d_channel_outputs, buffer, h_output_tensor.col * h_output_tensor.row * h_weight_tensor.channel_in * sizeof(unsigned int), cudaMemcpyHostToDevice);
		kernel_reduce_sum<<<(d_output_matrix.row * d_output_matrix.col + block_size - 1)/ block_size, block_size>>>(d_channel_outputs, d_output_matrix.arr,
																													d_output_matrix.col, d_output_matrix.row, h_output_tensor.channel);
		cudaMemcpy(h_output_tensor.arr[j], d_output_matrix.arr, sizeof(float) * h_output_tensor.row * h_output_tensor.col, cudaMemcpyDeviceToHost );
		cudaFree(d_channel_outputs);
		cudaFree(d_output_matrix.arr);

	}



	return h_output_tensor;
}

int main()
{
	int row = 512;
	int col = 512;
	int kernel_row = 3;
	int kernel_col = 3;

	int channel_in = 64;
	int channel_out = 1;
	matrix3d<float> input_tensor;
	weight4d<float> weight_tensor;
	input_tensor.row = row;
	input_tensor.col = col;
	input_tensor.channel = channel_in;
	// Init Matrices
	input_tensor.arr = new float *[input_tensor.channel]();
	for(int i=0; input_tensor.channel > i; ++i)
	{
		input_tensor.arr[i] = new float [input_tensor.row * input_tensor.col];
	}
	weight_tensor.row = kernel_row;
	weight_tensor.col = kernel_col;
	weight_tensor.channel_in = channel_in;
	weight_tensor.channel_out = channel_out;
	weight_tensor.arr = new float *[weight_tensor.channel_in * weight_tensor.channel_out]();
	for(int i=0; (weight_tensor.channel_in * weight_tensor.channel_out) > i ; ++i)
	{
		weight_tensor.arr[i] = new float [weight_tensor.row * weight_tensor.col];
	}
	bool padding = true;
	// Default Values
	for(int i=0; input_tensor.channel > i; ++i)
	{
		for (int j=0; input_tensor.col * input_tensor.row> j; ++j)
		{
			input_tensor.arr[i][j] = (rand() % 50) -0;
		}
	}
	for(int i=0; weight_tensor.channel_in * weight_tensor.channel_out > i; ++i)
	{
		for (int j=0; weight_tensor.col * weight_tensor.row> j; ++j)
		{
			weight_tensor.arr[i][j] = (rand() % 50) -0;
		}
	}
	// A sample layer

	matrix3d<float> output_matrix = xnor_convolution_v1(input_tensor, weight_tensor, padding);

	for (int i = 0; i < input_tensor.channel; i++)
	{
	    delete[] input_tensor.arr[i];
	}
	delete[] input_tensor.arr;

	for (int i = 0; i < output_matrix.channel; i++)
	{
	    delete[] output_matrix.arr[i];
	}
	delete[] output_matrix.arr;

	for (int i = 0; i < weight_tensor.channel_in * weight_tensor.channel_out; i++)
	{
	    delete[] weight_tensor.arr[i];
	}
	delete[] weight_tensor.arr;

	return 0;
}



