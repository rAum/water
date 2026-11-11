#[compute]
#version 450

// SPDX-FileCopyrightText: 2026 Piotr Gródek and the Flowing Water contributors
// SPDX-License-Identifier: Apache-2.0

// Red-black SOR pass for the bake's pressure projection.
// One invocation per cell; the push constant picks the red or black set.
// Conductances KX (nz x (nx+1)) and KZ ((nz+1) x nx) use the same layout as
// the GDScript solver; OPEN holds the extra conductance of pond outlet cells
// to outside pressure 0.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer PresBuf { float P[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer DivBuf { float DIV[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer KxBuf { float KX[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer KzBuf { float KZ[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer OpenBuf { float OPEN[]; };
layout(set = 0, binding = 5, std430) restrict readonly buffer SolidBuf { float SOLID[]; };

layout(push_constant, std430) uniform Params {
	int nx;
	int nz;
	int phase;      // 0 = red (i+j even), 1 = black
	int _pad;
	float omega;
	float _pad1;
	float _pad2;
	float _pad3;
} pc;

void main() {
	int i = int(gl_GlobalInvocationID.x);
	int j = int(gl_GlobalInvocationID.y);
	if (i >= pc.nx || j >= pc.nz) {
		return;
	}
	if (((i + j) & 1) != pc.phase) {
		return;
	}
	int k = j * pc.nx + i;
	if (SOLID[k] > 0.5) {
		return;
	}
	float kw = KX[j * (pc.nx + 1) + i];
	float ke = KX[j * (pc.nx + 1) + i + 1];
	float kn = KZ[j * pc.nx + i];
	float ks = KZ[(j + 1) * pc.nx + i];
	float ko = OPEN[k];
	float sum = kw + ke + kn + ks + ko;
	if (sum < 1e-9) {
		return;
	}
	float acc = 0.0;
	if (kw > 0.0) { acc += kw * P[k - 1]; }
	if (ke > 0.0) { acc += ke * P[k + 1]; }
	if (kn > 0.0) { acc += kn * P[k - pc.nx]; }
	if (ks > 0.0 && j < pc.nz - 1) { acc += ks * P[k + pc.nx]; }
	P[k] += pc.omega * ((acc - DIV[k]) / sum - P[k]);
}
