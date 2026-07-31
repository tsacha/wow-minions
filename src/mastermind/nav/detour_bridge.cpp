#include "detour_bridge.h"

#include <DetourAlloc.h>
#include <DetourCommon.h>
#include <DetourNavMesh.h>
#include <DetourNavMeshQuery.h>

#include <cstdint>
#include <cstring>
#include <vector>

namespace {

constexpr unsigned short nav_ground = 1 << (11 - 11);
constexpr unsigned short nav_ground_steep = 1 << (11 - 10);
constexpr unsigned short nav_water = 1 << (11 - 9);
constexpr unsigned short nav_magma_slime = 1 << (11 - 8);

constexpr int max_path_polys = 4096;
constexpr int max_query_nodes = 2048;

inline void wow_to_detour(const float* in_xyz, float* out_yzx) {
    out_yzx[0] = in_xyz[1];
    out_yzx[1] = in_xyz[2];
    out_yzx[2] = in_xyz[0];
}

inline void detour_to_wow(const float* in_yzx, float* out_xyz) {
    out_xyz[0] = in_yzx[2];
    out_xyz[1] = in_yzx[0];
    out_xyz[2] = in_yzx[1];
}

bool find_nearest_poly(dtNavMeshQuery* query, dtQueryFilter* filter, const float* point, dtPolyRef* out_ref, float* out_closest) {
    constexpr float extents_near[3] = { 5.0f, 5.0f, 5.0f };
    constexpr float extents_far[3] = { 20.0f, 20.0f, 20.0f };

    dtStatus st = query->findNearestPoly(point, extents_near, filter, out_ref, out_closest);
    if (dtStatusSucceed(st) && *out_ref != 0) return true;

    st = query->findNearestPoly(point, extents_far, filter, out_ref, out_closest);
    return dtStatusSucceed(st) && *out_ref != 0;
}

} // namespace

struct mb_detour_ctx {
    dtNavMesh* nav = nullptr;
    dtNavMeshQuery* query = nullptr;
    dtQueryFilter filter = dtQueryFilter();
    std::vector<unsigned char*> owned_tile_storage = {};
    bool initialized = false;
};

size_t mb_detour_navmesh_params_size(void) {
    return sizeof(dtNavMeshParams);
}

unsigned int mb_detour_navmesh_version(void) {
    return DT_NAVMESH_VERSION;
}

mb_detour_ctx* mb_detour_ctx_create(void) {
    mb_detour_ctx* ctx = new mb_detour_ctx();
    ctx->nav = dtAllocNavMesh();
    ctx->query = dtAllocNavMeshQuery();

    if (!ctx->nav || !ctx->query) {
        mb_detour_ctx_destroy(ctx);
        return nullptr;
    }

    const unsigned short include_flags = static_cast<unsigned short>(nav_ground | nav_water);
    const unsigned short exclude_flags = static_cast<unsigned short>(nav_ground_steep | nav_magma_slime);
    ctx->filter.setIncludeFlags(include_flags);
    ctx->filter.setExcludeFlags(exclude_flags);
    return ctx;
}

void mb_detour_ctx_destroy(mb_detour_ctx* ctx) {
    if (!ctx) return;
    if (ctx->query) dtFreeNavMeshQuery(ctx->query);
    if (ctx->nav) dtFreeNavMesh(ctx->nav);
    for (unsigned char* p : ctx->owned_tile_storage) {
        dtFree(p);
    }
    delete ctx;
}

int mb_detour_ctx_init_from_params(mb_detour_ctx* ctx, const void* params, size_t params_size) {
    if (!ctx || !ctx->nav || !ctx->query || !params) return 0;
    if (params_size != sizeof(dtNavMeshParams)) return 0;

    const dtStatus init_nav = ctx->nav->init(reinterpret_cast<const dtNavMeshParams*>(params));
    if (dtStatusFailed(init_nav)) return 0;

    const dtStatus init_query = ctx->query->init(ctx->nav, max_query_nodes);
    if (dtStatusFailed(init_query)) return 0;

    ctx->initialized = true;
    return 1;
}

int mb_detour_ctx_add_tile_copy(mb_detour_ctx* ctx, const void* data, size_t data_size) {
    if (!ctx || !ctx->initialized || !data || data_size == 0) return 0;

    if (data_size < sizeof(dtMeshHeader)) return 0;

    const dtMeshHeader* header = static_cast<const dtMeshHeader*>(data);
    const size_t header_size = static_cast<size_t>(dtAlign4(static_cast<int>(sizeof(dtMeshHeader))));
    const size_t verts_size = static_cast<size_t>(dtAlign4(static_cast<int>(sizeof(float) * 3 * header->vertCount)));
    const size_t polys_size = static_cast<size_t>(dtAlign4(static_cast<int>(sizeof(dtPoly) * header->polyCount)));
    const size_t links_offset = header_size + verts_size + polys_size;

    const size_t align_req = alignof(dtLink);
    unsigned char* tile_storage = static_cast<unsigned char*>(dtAlloc(data_size + align_req, DT_ALLOC_PERM));
    if (!tile_storage) return 0;

    unsigned char* tile_data = tile_storage;
    const std::uintptr_t addr = reinterpret_cast<std::uintptr_t>(tile_data);
    const size_t misalignment = static_cast<size_t>((addr + links_offset) % align_req);
    if (misalignment != 0) {
        tile_data += align_req - misalignment;
    }

    std::memcpy(tile_data, data, data_size);

    dtTileRef tile_ref = 0;
    const dtStatus st = ctx->nav->addTile(tile_data, static_cast<int>(data_size), 0, 0, &tile_ref);
    if (dtStatusFailed(st)) {
        dtFree(tile_storage);
        return 0;
    }

    ctx->owned_tile_storage.push_back(tile_storage);

    return 1;
}

int mb_detour_ctx_calc_tile_loc(mb_detour_ctx* ctx, const float* wow_xyz, int* out_tx, int* out_ty) {
    if (!ctx || !ctx->initialized || !wow_xyz || !out_tx || !out_ty) return 0;

    float detour_pos[3] = { 0.0f, 0.0f, 0.0f };
    wow_to_detour(wow_xyz, detour_pos);
    ctx->nav->calcTileLoc(detour_pos, out_tx, out_ty);
    return 1;
}

int mb_detour_ctx_collect_segments(mb_detour_ctx* ctx, mb_detour_segment* out_segments, int max_segments, int* out_count) {
    if (!ctx || !ctx->initialized || !out_segments || !out_count) return 0;
    if (max_segments <= 0) return 0;

    int count = 0;
    const dtNavMesh* nav = ctx->nav;
    const int max_tiles = nav->getMaxTiles();

    for (int ti = 0; ti < max_tiles; ti += 1) {
        const dtMeshTile* tile = nav->getTile(ti);
        if (!tile || !tile->header) continue;

        const dtMeshHeader* header = tile->header;
        for (int pi = 0; pi < header->polyCount; pi += 1) {
            const dtPoly* poly = &tile->polys[pi];
            if (poly->getType() == DT_POLYTYPE_OFFMESH_CONNECTION) continue;

            const unsigned int vert_count = static_cast<unsigned int>(poly->vertCount);
            for (unsigned int ei = 0; ei < vert_count; ei += 1) {
                const unsigned short nei = poly->neis[ei];
                if (nei != 0 && (nei & DT_EXT_LINK) == 0) {
                    const unsigned int nei_poly = static_cast<unsigned int>(nei - 1);
                    if (nei_poly < static_cast<unsigned int>(pi)) {
                        continue;
                    }
                }

                const unsigned int va_idx = static_cast<unsigned int>(poly->verts[ei]);
                const unsigned int vb_idx = static_cast<unsigned int>(poly->verts[(ei + 1) % vert_count]);
                const float* va = &tile->verts[va_idx * 3];
                const float* vb = &tile->verts[vb_idx * 3];

                if (count >= max_segments) {
                    *out_count = count;
                    return 1;
                }

                mb_detour_segment* seg = &out_segments[count];
                detour_to_wow(va, &seg->ax);
                detour_to_wow(vb, &seg->bx);
                count += 1;
            }
        }
    }

    *out_count = count;
    return 1;
}

int mb_detour_ctx_find_path(
    mb_detour_ctx* ctx,
    const float* start_wow_xyz,
    const float* end_wow_xyz,
    float* out_wow_xyz,
    int max_points,
    int* out_points
) {
    if (!ctx || !ctx->initialized || !start_wow_xyz || !end_wow_xyz || !out_wow_xyz || !out_points) return 0;
    if (max_points <= 0) return 0;

    float start_detour[3] = { 0.0f, 0.0f, 0.0f };
    float end_detour[3] = { 0.0f, 0.0f, 0.0f };
    wow_to_detour(start_wow_xyz, start_detour);
    wow_to_detour(end_wow_xyz, end_detour);

    dtPolyRef start_poly = 0;
    dtPolyRef end_poly = 0;
    float start_closest[3] = { 0.0f, 0.0f, 0.0f };
    float end_closest[3] = { 0.0f, 0.0f, 0.0f };

    if (!find_nearest_poly(ctx->query, &ctx->filter, start_detour, &start_poly, start_closest)) return 0;
    if (!find_nearest_poly(ctx->query, &ctx->filter, end_detour, &end_poly, end_closest)) return 0;

    dtPolyRef polys[max_path_polys] = {};
    int poly_count = 0;
    const dtStatus path_status = ctx->query->findPath(
        start_poly,
        end_poly,
        start_closest,
        end_closest,
        &ctx->filter,
        polys,
        &poly_count,
        max_path_polys
    );
    if (dtStatusFailed(path_status) || poly_count <= 0) return 0;

    std::vector<float> straight(static_cast<size_t>(max_points) * 3);
    std::vector<unsigned char> straight_flags(static_cast<size_t>(max_points));
    std::vector<dtPolyRef> straight_refs(static_cast<size_t>(max_points));

    int straight_count = 0;
    const dtStatus straight_status = ctx->query->findStraightPath(
        start_closest,
        end_closest,
        polys,
        poly_count,
        straight.data(),
        straight_flags.data(),
        straight_refs.data(),
        &straight_count,
        max_points
    );
    if (dtStatusFailed(straight_status) || straight_count <= 0) return 0;

    for (int i = 0; i < straight_count; i += 1) {
        detour_to_wow(&straight[static_cast<size_t>(i) * 3], &out_wow_xyz[static_cast<size_t>(i) * 3]);
    }
    *out_points = straight_count;
    return 1;
}
