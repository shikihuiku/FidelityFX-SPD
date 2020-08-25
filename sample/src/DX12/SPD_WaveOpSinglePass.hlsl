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

//--------------------------------------------------------------------------------------
// Constant Buffer
//--------------------------------------------------------------------------------------
cbuffer spdConstants : register(b0)
{
	uint mips;
	uint numWorkGroups;
	uint thread_group_width;
	uint thread_group_height;
}

//--------------------------------------------------------------------------------------
// Texture definitions
//--------------------------------------------------------------------------------------

#define GLB_COH globallycoherent
//#define GLB_COH

#define USE_UAV_ARRAY 0

#if USE_UAV_ARRAY
GLB_COH RWTexture2D<float4>            imgDst[12]      : register(u2);
#else
GLB_COH RWTexture2D<float4>            imgDst0      : register(u2);
GLB_COH RWTexture2D<float4>            imgDst1      : register(u3);
GLB_COH RWTexture2D<float4>            imgDst2      : register(u4);
GLB_COH RWTexture2D<float4>            imgDst3      : register(u5);
GLB_COH RWTexture2D<float4>            imgDst4      : register(u6);
GLB_COH RWTexture2D<float4>            imgDst5      : register(u7);
GLB_COH RWTexture2D<float4>            imgDst6      : register(u8);
GLB_COH RWTexture2D<float4>            imgDst7      : register(u9);
GLB_COH RWTexture2D<float4>            imgDst8      : register(u10);
GLB_COH RWTexture2D<float4>            imgDst9      : register(u11);
GLB_COH RWTexture2D<float4>            imgDst10      : register(u12);
GLB_COH RWTexture2D<float4>            imgDst11      : register(u13);
#endif
#undef GLB_COH

Texture2D<float4>              imgSrc      : register(t0);

//--------------------------------------------------------------------------------------
// Buffer definitions - global atomic counter
//--------------------------------------------------------------------------------------
// used as [16][16] atomic counters for deciding the last thread in each 16x16 thread group, when using numthread[8x8].
RWByteAddressBuffer globalAtomic :register(u1);
groupshared uint atomicValue;

#ifdef NUMTHREAD_256
groupshared float4 spd_intermediate[16][16];
#else
groupshared float4 spd_intermediate[4][4];
#endif

#define A_GPU
#define A_HLSL

#include "ffx_a.h"

void SpdStoreIntermediate(AU1 x, AU1 y, AF4 value) { spd_intermediate[y][x] = value; }
float4 SpdLoadIntermediate(AU1 x, AU1 y) { return spd_intermediate[y][x]; }

#if USE_UAV_ARRAY
void SpdStore(ASU2 pix, AF4 outValue, AU1 index) { imgDst[index][pix] = outValue; }
AF4 SpdLoad(ASU2 pix, AU1 index) { return imgDst[index][pix]; }
#else
void SpdStore(ASU2 pix, AF4 outValue, AU1 index) {
	switch (index) {
	case 0:
		imgDst0[pix] = outValue;
		break;
	case 1:
		imgDst1[pix] = outValue;
		break;
	case 2:
		imgDst2[pix] = outValue;
		break;
	case 3:
		imgDst3[pix] = outValue;
		break;
	case 4:
		imgDst4[pix] = outValue;
		break;
	case 5:
		imgDst5[pix] = outValue;
		break;
	case 6:
		imgDst6[pix] = outValue;
		break;
	case 7:
		imgDst7[pix] = outValue;
		break;
	case 8:
		imgDst8[pix] = outValue;
		break;
	case 9:
		imgDst9[pix] = outValue;
		break;
	case 10:
		imgDst10[pix] = outValue;
		break;
	case 11:
		imgDst11[pix] = outValue;
		break;
	default:
		break;
	}
}
AF4 SpdLoad(ASU2 pix, AU1 index) {
	switch (index) {
	case 0:
		return imgDst0[pix];
	case 1:
		return imgDst1[pix];
	case 2:
		return imgDst2[pix];
	case 3:
		return imgDst3[pix];
	case 4:
		return imgDst4[pix];
	case 5:
		return imgDst5[pix];
	case 6:
		return imgDst6[pix];
	case 7:
		return imgDst7[pix];
	case 8:
		return imgDst8[pix];
	case 9:
		return imgDst9[pix];
	case 10:
		return imgDst10[pix];
	case 11:
		return imgDst11[pix];
	default:
		break;
	}
	return AF4(0, 0, 0, 0);
}
#endif

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

AF4 SpdLoadSourceImage(ASU2 tex) { return imgSrc[tex]; }
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

AF4 SpdLoadMipImage(ASU2 tex, AU1 idx) { return SpdLoad(tex, idx); }

AF4 SpdReduceLoadMipImage4(AU2 i0, AU2 i1, AU2 i2, AU2 i3, AU1 idx)
{
	AF4 v0 = SpdLoadMipImage(ASU2(i0), idx);
	AF4 v1 = SpdLoadMipImage(ASU2(i1), idx);
	AF4 v2 = SpdLoadMipImage(ASU2(i2), idx);
	AF4 v3 = SpdLoadMipImage(ASU2(i3), idx);
	return SpdReduce4(v0, v1, v2, v3);
}

AF4 SpdReduceLoadMipImage4(AU2 base, AU1 idx)
{
	return SpdReduceLoadMipImage4(
		AU2(base + AU2(0, 0)),
		AU2(base + AU2(0, 1)),
		AU2(base + AU2(1, 0)),
		AU2(base + AU2(1, 1)), idx);
}

#ifndef NUMTHREAD_256

void Reduction8_4_2_1(AF4 value, AU2 sub_xy, AU2 workGroupID, AU1 localInvocationIndex, AU1 baseMip, AU1 mips)
{
	if (mips <= baseMip)
		return;

	// baseMip-1[16x16] -> baseMip[8x8]

#ifndef SPD_NO_WAVE_OPERATIONS
	// Do redcution with 0, 1, 2 and 3 lane
	value += WaveReadLaneAt(value, WaveGetLaneIndex() ^ 0b0001); // 0-1, 2-3,...
	value += WaveReadLaneAt(value, WaveGetLaneIndex() ^ 0b0010); // 0-2, 1-3,...
	value *= 0.25;
#else
	value = float4(0, 0, 0, 1);
#endif

	// baseMip[4x4]
	if (localInvocationIndex % 4 == 0) {
		ASU2 local_xy = sub_xy >> 1;
		AU2 pix = workGroupID.xy * 4 + local_xy;

		SpdStore(pix, value, baseMip);
		SpdStoreIntermediate(local_xy.x, local_xy.y, value);
	}

	if (mips <= baseMip + 1)
		return;

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

		// baseMip+1[2x2]
		if (localInvocationIndex % 4 == 0) {
			AU2 pix = workGroupID.xy * 2 + (sub_xy >> 1);

			SpdStore(pix, value, baseMip+1);

			if (mips > baseMip + 2) {
				// baseMip+2[1x1]
#ifndef SPD_NO_WAVE_OPERATIONS
				// Do redcution with 0, 4, 8 and 12 lane
				value += WaveReadLaneAt(value, WaveGetLaneIndex() ^ 0b00100); // 0-4, 1-5,...
				value += WaveReadLaneAt(value, WaveGetLaneIndex() ^ 0b01000); // 0-8, 1-9,...
				value *= 0.25;
#endif

				if (localInvocationIndex == 0) {
					pix = workGroupID.xy;

					SpdStore(pix, value, baseMip+2);
				}
			}
		}
	}
}

// numthread = 64
void SpdDownsample64(
	AU2 workGroupID,
	AU1 localInvocationIndex,
	AU1 mips
) {
	AU2 sub_xy = MortonEncode8x8(localInvocationIndex);

	AF4 value;

	// Mip0[8x8]
	{
		ASU2 tex = ASU2(workGroupID.xy * 16) + sub_xy * 2;
		AU2 pix = workGroupID.xy * 8 + sub_xy;
		value = SpdReduceLoadSourceImage4(tex);

		SpdStore(pix, value, 0);
	}

	if (mips <= 1)
		return;

	// Mip0[8x8]->Mip1[4x4]->Mip2[2x2]->Mip3[1x1]
	Reduction8_4_2_1(value, sub_xy, workGroupID, localInvocationIndex, 1, mips);

	if (mips <= 4)
		return;

	// Mip3 need to be updated completely before incremnting the atomic values.
	DeviceMemoryBarrierWithGroupSync();

	if (localInvocationIndex == 0) {
		// increment a corresponding position in atomicCounterGrid[16][16]
		AU2 atomicLocation = workGroupID / 16;
		globalAtomic.InterlockedAdd(4 * (atomicLocation.x + atomicLocation.y * 16), 1, atomicValue);
	}

	// this is for sharing the atomicadd's return result.
	GroupMemoryBarrierWithGroupSync();

	// exit all threads if this thread group is not the last one of each 16x16 thread groups.
	if (atomicValue < 16 * 16 - 1)
		return;

	// from here, only the last thread group of each 16x16 thread group tile.

	// rearrange group id.
	workGroupID = workGroupID / 16;

	// Mip4[8x8]
	{
		ASU2 tex = ASU2(workGroupID.xy * 16) + sub_xy * 2;
		AU2 pix = workGroupID.xy * 8 + sub_xy;

		// load mip3
		value = SpdReduceLoadMipImage4(tex, 3);

		SpdStore(pix, value, 4);
	}

	if (mips <= 5)
		return;

	// Mip4[8x8]->Mip5[4x4]->Mip6[2x2]->Mip7[1x1]
	Reduction8_4_2_1(value, sub_xy, workGroupID, localInvocationIndex, 5, mips);

	if (mips <= 8)
		return;

	// mip7 need to be updated completely before incremnting the atomic values.
	DeviceMemoryBarrierWithGroupSync();

	if (localInvocationIndex == 0) {
		globalAtomic.InterlockedAdd(4 * 16*16, 1, atomicValue);
	}

	GroupMemoryBarrierWithGroupSync();

	// exit all threads if this thread group is not the last one of each 16x16 thread groups.
	if (atomicValue < 16 * 16 - 1)
		return;

	// rearrange group id.
	workGroupID = workGroupID / 16;

	// Mip8[8x8]
	{
		ASU2 tex = ASU2(workGroupID.xy * 16) + sub_xy * 2;
		AU2 pix = workGroupID.xy * 8 + sub_xy;

		// load mip7
		value = SpdReduceLoadMipImage4(tex, 7);

		SpdStore(pix, value, 8);
	}

	if (mips <= 9)
		return;

	// Mip6[8x8]->Mip9[4x4]->Mip10[2x2]->Mip11[1x1]
	Reduction8_4_2_1(value, sub_xy, workGroupID, localInvocationIndex, 9, mips);
}

#endif // ifndef NUMTHREAD_256

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

AF4 SpdDownsampleUAVMips_two_step(AU1 srcUAVIdx, AU2 sub_xy, AU1 localInvocationIndex, AU1 baseMip, AU1 mips)
{
	[unroll]
	for (int i = 0; i < 4; i++)
	{
		ASU2 pixOfs = ASU2((i % 2) * 16, (i / 2) * 16);
		ASU2 pix = pixOfs + sub_xy;
		ASU2 tex = pix * 2;

		AF4 value = SpdReduceLoadMipImage4(tex, srcUAVIdx);

		SpdStore(pix, value, baseMip);

		value += WaveReadLaneAt(value, WaveGetLaneIndex() ^ 0b001); // 0-1, 2-3,...
		value += WaveReadLaneAt(value, WaveGetLaneIndex() ^ 0b010); // 0-2, 1-3,...
		value *= 0.25;

		if ((localInvocationIndex % 4) == 0 && mips > baseMip)
		{
			pix /= 2;
			ASU2 local_xy = pix % 16;
			SpdStore(pix, value, baseMip + 1);
			SpdStoreIntermediate(local_xy.x, local_xy.y, value);
		}
	}

	if (mips <= baseMip + 1)
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

	if (mips <= 5)
		return;

	// mip5 need to be updated completely before incremnting the atomic values.
	DeviceMemoryBarrierWithGroupSync();

	if (localInvocationIndex == 0) {
		globalAtomic.InterlockedAdd(0, 1, atomicValue);
	}

	// this is for sharing the atomicadd's return result.
	GroupMemoryBarrierWithGroupSync();

	// exit all threads groups except the last one
	if (atomicValue < numWorkGroups - 1)
		return;

	// Mip5[64x64] -> Mip6[32x32] -> Mip7[16x16]
	value = SpdDownsampleUAVMips_two_step(5, sub_xy, localInvocationIndex, 6, mips);

	// Mip7[16x16] -> Mip8[8x8] -> Mip9[4x4] -> Mip10[2x2] -> Mip11[1x1]
	workGroupID.xy = AU2(0, 0);
	Reduction16_8_4_2_1(value, sub_xy, workGroupID, localInvocationIndex, 8, mips);
}

#endif // NUMTHREAD_256

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
	AU2 workGroupPos = WorkGroupId.xy;

#ifdef NUMTHREAD_256
	SpdDownsample256(
		workGroupPos,
		AU1(LocalThreadIndex),
		AU1(mips));
#else
	SpdDownsample64(
		workGroupPos,
		AU1(LocalThreadIndex),
		AU1(mips));
#endif
}
