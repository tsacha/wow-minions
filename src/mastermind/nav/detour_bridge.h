#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct mb_detour_ctx mb_detour_ctx;

typedef struct mb_detour_segment {
    float ax;
    float ay;
    float az;
    float bx;
    float by;
    float bz;
} mb_detour_segment;

size_t mb_detour_navmesh_params_size(void);
unsigned int mb_detour_navmesh_version(void);

mb_detour_ctx* mb_detour_ctx_create(void);
void mb_detour_ctx_destroy(mb_detour_ctx* ctx);

int mb_detour_ctx_init_from_params(mb_detour_ctx* ctx, const void* params, size_t params_size);
int mb_detour_ctx_add_tile_copy(mb_detour_ctx* ctx, const void* data, size_t data_size);
int mb_detour_ctx_calc_tile_loc(mb_detour_ctx* ctx, const float* wow_xyz, int* out_tx, int* out_ty);
int mb_detour_ctx_collect_segments(mb_detour_ctx* ctx, mb_detour_segment* out_segments, int max_segments, int* out_count);

int mb_detour_ctx_find_path(
    mb_detour_ctx* ctx,
    const float* start_wow_xyz,
    const float* end_wow_xyz,
    float* out_wow_xyz,
    int max_points,
    int* out_points
);

#ifdef __cplusplus
}
#endif
