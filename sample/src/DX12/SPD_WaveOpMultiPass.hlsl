// SPDSample
//
// Copyright (c) 2020 Advanced Micro Devices, Inc. All rights reserved.
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

// when using amd shader intrinscs
// #include "ags_shader_intrinsics_dx12.h"

//--------------------------------------------------------------------------------------
// Constant Buffer
//--------------------------------------------------------------------------------------
cbuffer spdConstants : register(b0)
{
	uint mips;
	uint numWorkGroups;
	// [SAMPLER]
	float2 invInputSize;
	uint4 threadGroupDim;
}

//--------------------------------------------------------------------------------------
// Texture definitions
//--------------------------------------------------------------------------------------
#ifdef NUMTHREAD_256
RWTexture2D<float4>            imgDst[6]      : register(u2);
#else
RWTexture2D<float4>            imgDst[4]      : register(u2);
#endif

Texture2D<float4>              imgSrc      : register(t0);

//--------------------------------------------------------------------------------------
// Buffer definitions - global atomic counter
//--------------------------------------------------------------------------------------
#ifndef NUMTHREAD_256
groupshared float4 spd_intermediate[8][8];
#else
groupshared float4 spd_intermediate[16][16];
#endif

#define A_GPU
#define A_HLSL

#include "ffx_a.h"

void SpdStoreIntermediate(AU1 x, AU1 y, AF4 value) { spd_intermediate[y][x] = value; }
AF4 SpdLoadIntermediate(AU1 x, AU1 y) { return spd_intermediate[y][x]; }

void SpdStore(ASU2 pix, AF4 outValue, AU1 index) { imgDst[index][pix] = outValue; }
AF4 SpdLoad(ASU2 pix, AU1 index) { return imgDst[index][pix]; }

AU2 MortonEncode8x8(AU1 a)
{
	//  ===================
	//  00 01 04 05 10 11 14 15 
	//  02 03 06 07 12 13 16 17
	//  08 09 0c 0d 18 19 1c 1d
	//  0a 0b 0e 0f 1a 1b 1e 1f 
	//  20 21 24 25 30 31 34 35  
	//  22 23 26 27 32 33 36 37 
	//  28 29 2c 2d 38 39 3c 3d
	//  2a 2b 2e 2f 3a 3b 3e 3f 
	// x = 01012323, 01012323, 45456767, 45456767, 01012323, 01012323, 45456767, 45456767
	// y = 00110011, 22332233, 00110011, 22332233, 44554455, 66776677, 44554455, 66776677, 

	// x = a & 1 | a >> 1 & 0b010 | a >> 2 & 0b100;
	// y = a >> 1 & 0b001 | a >> 2 & 0b110 

	// 8x8
	AU1 a1 = a >> 1;
	AU1 a2 = a >> 2;
	AU1 a3 = a >> 3;
	AU1 x = (a & 0b001) | (a1 & 0b010) | (a2 & 0b100);
	AU1 y = (a1 & 0b001) | (a2 & 0b010) | (a3 & 0b100);

	// column major morton.
	return AU2(y, x);
}

AU2 MortonEncode16x16(AU1 a)
{
	AU2 xy = MortonEncode8x8(a);

	// 16x16
	AU1 tileIdx = a / 64;

	// column major morton.
	xy.x += 8 * (tileIdx / 2);
	xy.y += 8 * (tileIdx % 2);

	return xy;
}

#define REMAP_THREAD_GROUP 0
#ifdef REMAP_THREAD_GROUP
uint2 RemapThreadGroup(uint32_t group_width, uint32_t group_height, uint32_t x_stride, uint32_t y_stride, uint32_t flatten_id)
{
	uint32_t perfect_tile_size = x_stride * y_stride;

	uint32_t number_of_perfect_tiles_in_x = group_width / x_stride;
	uint32_t number_of_groups_in_the_last_tile_in_x_dir = group_width - number_of_perfect_tiles_in_x * x_stride;

	uint32_t number_of_perfect_tiles_in_y = group_height / y_stride;
	uint32_t number_of_groups_in_the_last_tile_in_y_dir = group_height - number_of_perfect_tiles_in_y * y_stride;

	uint32_t number_of_groups_in_the_last_tile_in_x = number_of_groups_in_the_last_tile_in_x_dir * y_stride;
	uint32_t number_of_groups_in_the_last_tile_in_y = number_of_groups_in_the_last_tile_in_y_dir * x_stride;

	uint32_t remaining_id = flatten_id;
	uint32_t tile_x = 0;
	uint32_t tile_y = 0;
	uint32_t local_x = 0;
	uint32_t local_y = 0;

	// locate the tile position and calc remaining groups.
	{
		uint32_t number_of_groups_in_a_tile_line = number_of_perfect_tiles_in_x * perfect_tile_size + number_of_groups_in_the_last_tile_in_x;

		uint32_t perfect_x_tile_lines = remaining_id / number_of_groups_in_a_tile_line;
		remaining_id -= perfect_x_tile_lines * number_of_groups_in_a_tile_line;
		tile_y += perfect_x_tile_lines;
	}

	if (tile_y < number_of_perfect_tiles_in_y) {
		// in a middle of a line.
		uint32_t perfect_x_tiles = remaining_id / perfect_tile_size;
		remaining_id -= perfect_x_tiles * perfect_tile_size;
		tile_x += perfect_x_tiles;
	}
	else {
		// the last line.
		uint32_t x_tiles = remaining_id / number_of_groups_in_the_last_tile_in_y;
		remaining_id -= x_tiles * number_of_groups_in_the_last_tile_in_y;
		tile_x += x_tiles;
	}

	// locate position in a tile
	if (tile_x < number_of_perfect_tiles_in_x) {
		// middle in x
		local_y = remaining_id / x_stride;
		local_x = remaining_id - local_y * x_stride;
		remaining_id = 0;
	}
	else {
		// the last in x
		local_y = remaining_id / number_of_groups_in_the_last_tile_in_x_dir;
		local_x = remaining_id - local_y * number_of_groups_in_the_last_tile_in_x_dir;
		remaining_id = 0;
	}

	return uint2(local_x + tile_x * x_stride, local_y + tile_y * y_stride);
};

#endif

AF4 SpdLoadSourceImage(AF2 tex) { return imgSrc[tex]; }
AF4 SpdReduce4(AF4 v0, AF4 v1, AF4 v2, AF4 v3) { return (v0 + v1 + v2 + v3) * 0.25; }

AF4 SpdReduceLoadSourceImage4(AU2 i0, AU2 i1, AU2 i2, AU2 i3)
{
	AF4 v0 = SpdLoadSourceImage(ASU2(i0));
	AF4 v1 = SpdLoadSourceImage(ASU2(i1));
	AF4 v2 = SpdLoadSourceImage(ASU2(i2));
	AF4 v3 = SpdLoadSourceImage(ASU2(i3));
	return SpdReduce4(v0, v1, v2, v3);
}

AF4 SpdReduceLoadSourceImage4(AU2 base)
{
	return SpdReduceLoadSourceImage4(
		AU2(base + AU2(0, 0)),
		AU2(base + AU2(0, 1)),
		AU2(base + AU2(1, 0)),
		AU2(base + AU2(1, 1)));
}

#ifndef NUMTHREAD_256

void SpdDownsample64(
	AU2 workGroupID,
	AU1 localInvocationIndex,
	AU1 mips
) {
	AU2 sub_xy = MortonEncode8x8(localInvocationIndex);

	AF4 value;
	// Mip0 [8x8]
	{
		ASU2 tex = ASU2(workGroupID.xy * 16) + sub_xy * 2;
		AU2 pix = workGroupID.xy * 8 + sub_xy;
		value = SpdReduceLoadSourceImage4(tex);

		SpdStore(pix, value, 0);
	}

	if (mips <= 1)
		return;

#ifndef SPD_NO_WAVE_OPERATIONS
	// Do redcution with 0, 1, 2 and 3 lane
	value += WaveReadLaneAt(value, WaveGetLaneIndex() ^ 0b0001); // 0-1, 2-3,...
	value += WaveReadLaneAt(value, WaveGetLaneIndex() ^ 0b0010); // 0-2, 1-3,...
	value *= 0.25;
#else
	value = float4(0, 0, 0, 1);
#endif

	// Mip1 [4x4]
	if (localInvocationIndex % 4 == 0) {
		ASU2 local_xy = sub_xy >> 1;
		AU2 pix = workGroupID.xy * 4 + local_xy;

		SpdStore(pix, value, 1);
		SpdStoreIntermediate(local_xy.x, local_xy.y, value);
	}

	if (mips <= 2)
		return;

	// rearrange pixels using shared mem.
	GroupMemoryBarrierWithGroupSync();

	// using the first one warp or wavefront.
	if (localInvocationIndex < 16) {
		value = SpdLoadIntermediate(sub_xy.x, sub_xy.y);

#ifndef SPD_NO_WAVE_OPERATIONS
		// Do redcution with 0, 1, 2 and 3 lane
		value += WaveReadLaneAt(value, WaveGetLaneIndex() ^ 0b0001); // 0-1, 2-3,...
		value += WaveReadLaneAt(value, WaveGetLaneIndex() ^ 0b0010); // 0-2, 1-3,...
		value *= 0.25;
#endif

		// Mip2[2x2]
		if (localInvocationIndex % 4 == 0) {
			AU2 pix = workGroupID.xy * 2 + (sub_xy >> 1);

			SpdStore(pix, value, 2);

			if (mips >= 4) {
				// Mip3[1x1]
#ifndef SPD_NO_WAVE_OPERATIONS
				// Do redcution with 0, 4, 8 and 12 lane
				value += WaveReadLaneAt(value, WaveGetLaneIndex() ^ 0b00100); // 0-4, 1-5,...
				value += WaveReadLaneAt(value, WaveGetLaneIndex() ^ 0b01000); // 0-8, 1-9,...
				value *= 0.25;
#endif

				if (localInvocationIndex == 0) {
					pix = workGroupID.xy;

					SpdStore(pix, value, 3);
				}
			}
		}
	}
}

#endif

#ifdef NUMTHREAD_256

AF4 SpdDownsampleMips_0_1(AU2 sub_xy, AU2 workGroupID, AU1 localInvocationIndex, AU1 mip)
{
	// Src[64x64] -> Mip0[32x32] -> Mip1[16x16]
	// |*-|
	// |--| process each 1/4 of tex region.
	[unroll]
	for (int i=0; i<4; i++)
	{
		ASU2 pixOfs = ASU2((i % 2) * 16, (i / 2) * 16);
		ASU2 pix = AU2(workGroupID.xy * 32) + pixOfs + sub_xy;
		ASU2 tex = pix * 2;
		AF4 value = SpdReduceLoadSourceImage4(tex);
		SpdStore(pix, value, 0);

		value += WaveReadLaneAt(value, WaveGetLaneIndex() ^ 0b001); // 0-1, 2-3,...
		value += WaveReadLaneAt(value, WaveGetLaneIndex() ^ 0b010); // 0-2, 1-3,...
		value *= 0.25;

		if ((localInvocationIndex % 4) == 0 && mip > 1)
		{
			pix /= 2;
			ASU2 local_xy = pix % 16;
			SpdStore(pix, value, 1);
			SpdStoreIntermediate(local_xy.x, local_xy.y, value);
		}
	}

	if (mip <= 1)
		return AF4(0, 0, 0, 0);

	// rearrange pixels using shared mem.
	GroupMemoryBarrierWithGroupSync();

	return SpdLoadIntermediate(sub_xy.x, sub_xy.y);
}

void Reduction16_8_4_2_1(AF4 value, AU2 sub_xy, AU2 workGroupID, AU1 localInvocationIndex, AU1 baseMip, AU1 mips)
{
	if (mips <= baseMip)
		return;

	// baseMip-1[16x16] -> baseMip[8x8]
#ifndef SPD_NO_WAVE_OPERATIONS
	// Do redcution with 0, 1, 2 and 3 lane
	value += WaveReadLaneAt(value, WaveGetLaneIndex() ^ 0b001); // 0-1, 2-3,...
	value += WaveReadLaneAt(value, WaveGetLaneIndex() ^ 0b010); // 0-2, 1-3,...
	value *= 0.25;
#endif

	// to complete read op of sharedmem.
	GroupMemoryBarrierWithGroupSync();

	if (localInvocationIndex % 4 == 0) {
		AU2 pix = workGroupID.xy * 8 + (sub_xy >> 1);

		SpdStore(pix, value, baseMip);

		AU1 flattenID = localInvocationIndex / 4; // 0~63
		SpdStoreIntermediate(flattenID % 16, flattenID / 16, value);
	}

	if (mips <= baseMip + 1)
		return;

	GroupMemoryBarrierWithGroupSync();

	// use the first 8x8 for further process.
	if (localInvocationIndex < 64) {
		value = SpdLoadIntermediate(localInvocationIndex % 16, localInvocationIndex / 16);

		// baseMip[8x8] -> baseMip+1[4x4]
#ifndef SPD_NO_WAVE_OPERATIONS
		// Do redcution with 0, 1, 2 and 3 lane
		value += WaveReadLaneAt(value, WaveGetLaneIndex() ^ 0b001);
		value += WaveReadLaneAt(value, WaveGetLaneIndex() ^ 0b010);
		value *= 0.25;
#endif

		if (localInvocationIndex % 4 == 0) {
			AU2 pix = workGroupID.xy * 4 + (sub_xy >> 1);

			SpdStore(pix, value, baseMip + 1);

			// to avoid RW hazard.
			SpdStoreIntermediate(localInvocationIndex / 4, 8, value); // 0~16
		}
	}

	if (mips <= baseMip + 2)
		return;

	GroupMemoryBarrierWithGroupSync();

	// using the first one warp or wavefront.
	if (localInvocationIndex < 16) {
		value = SpdLoadIntermediate(localInvocationIndex, 8);

#ifndef SPD_NO_WAVE_OPERATIONS
		// Do redcution with 0, 1, 2 and 3 lane
		value += WaveReadLaneAt(value, WaveGetLaneIndex() ^ 0b001);
		value += WaveReadLaneAt(value, WaveGetLaneIndex() ^ 0b010);
		value *= 0.25;
#endif
		if (localInvocationIndex % 4 == 0) {
			AU2 pix = workGroupID.xy * 2 + (sub_xy >> 1);

			SpdStore(pix, value, baseMip + 2);

			if (mips >= baseMip + 4) {
				// baseMip+2[2x2] -> baseMip+3[1x1]
#ifndef SPD_NO_WAVE_OPERATIONS
				// Do redcution with 0, 4, 8 and 12 lane
				value += WaveReadLaneAt(value, WaveGetLaneIndex() ^ 0b00100); // 0-4, 1-5,...
				value += WaveReadLaneAt(value, WaveGetLaneIndex() ^ 0b01000); // 0-8, 1-9,...
				value *= 0.25;
#endif

				if (localInvocationIndex == 0) {
					pix = workGroupID.xy;

					SpdStore(pix, value, baseMip + 3);
				}
			}
		}
	}
}

// numthread = 256, total miplevels = 12, renders 11 layers
void SpdDownsample256(
	AU2 workGroupID,
	AU1 localInvocationIndex,
	AU1 mips
)
{
	AU2 sub_xy = MortonEncode16x16(localInvocationIndex);

	// Src[64x64] -> Mip0[32x32] -> Mip1[16x16]
	AF4 value = SpdDownsampleMips_0_1(sub_xy, workGroupID, localInvocationIndex, mips);

	// Mip1[16x16] -> Mip2[8x8] -> Mip3[4x4] -> Mip4[2x2] -> Mip5[1x1]
	Reduction16_8_4_2_1(value, sub_xy, workGroupID, localInvocationIndex, 2, mips);
}

#endif

// Main function
//--------------------------------------------------------------------------------------
//--------------------------------------------------------------------------------------
#ifdef NUMTHREAD_256
[numthreads(256, 1, 1)]
#else
[numthreads(64, 1, 1)]
#endif
void main(uint3 WorkGroupId : SV_GroupID, uint LocalThreadIndex : SV_GroupIndex)
{
#ifdef NUMTHREAD_256
	AU2 workGroupPos = WorkGroupId.xy;

	SpdDownsample256(
		workGroupPos,
		AU1(LocalThreadIndex),
		AU1(mips));
#else
#ifdef REMAP_THREAD_GROUP
	uint flattenID = WorkGroupId.x + WorkGroupId.y * threadGroupDim.x;
	AU2 workGroupPos = RemapThreadGroup(threadGroupDim.x, threadGroupDim.y, 8, 8, flattenID);
#else
	AU2 workGroupPos = WorkGroupId.xy;
#endif

	SpdDownsample64(
		workGroupPos,
		AU1(LocalThreadIndex),
		AU1(mips));
#endif
}


