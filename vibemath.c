#include <immintrin.h>
#include <stdint.h>
#include <stdbool.h>
#include <math.h>

// ========================================================
// CROSS-PLATFORM FFI EXPORT MACRO
// ========================================================
#ifdef _WIN32
    // Windows DLL export
    #define EXPORT __declspec(dllexport)
#else
    // Linux/macOS Shared Object export
    #define EXPORT __attribute__((visibility("default")))
#endif

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif
#define CAGE_FACTOR 32
// ========================================================
// CROSS-PLATFORM THREADING BRIDGE (Mutex & CondVars)
// ========================================================
#if defined(_WIN32) || defined(_WIN64)
    #include <windows.h>
    typedef HANDLE vmath_thread_t;
    typedef CRITICAL_SECTION vmath_mutex_t;
    typedef CONDITION_VARIABLE vmath_cond_t;
    #define THREAD_FUNC DWORD WINAPI
    #define THREAD_RETURN_VAL 0
    static vmath_thread_t vmath_thread_start(DWORD (WINAPI *func)(LPVOID), void* arg) { return CreateThread(NULL, 0, func, arg, 0, NULL); }
    static void vmath_thread_join(vmath_thread_t thread) { WaitForSingleObject(thread, INFINITE); CloseHandle(thread); }
    static void vmath_mutex_init(vmath_mutex_t* m) { InitializeCriticalSection(m); }
    static void vmath_mutex_lock(vmath_mutex_t* m) { EnterCriticalSection(m); }
    static void vmath_mutex_unlock(vmath_mutex_t* m) { LeaveCriticalSection(m); }
    static void vmath_mutex_destroy(vmath_mutex_t* m) { DeleteCriticalSection(m); }
    static void vmath_cond_init(vmath_cond_t* cv) { InitializeConditionVariable(cv); }
    static void vmath_cond_wait(vmath_cond_t* cv, vmath_mutex_t* m) { SleepConditionVariableCS(cv, m, INFINITE); }
    static void vmath_cond_broadcast(vmath_cond_t* cv) { WakeAllConditionVariable(cv); }
    static void vmath_cond_destroy(vmath_cond_t* cv) { }
#else
    #include <pthread.h>
    typedef pthread_t vmath_thread_t;
    typedef pthread_mutex_t vmath_mutex_t;
    typedef pthread_cond_t vmath_cond_t;
    #define THREAD_FUNC void*
    #define THREAD_RETURN_VAL NULL
    static vmath_thread_t vmath_thread_start(void* (*func)(void*), void* arg) { pthread_t thread; pthread_create(&thread, NULL, func, arg); return thread; }
    static void vmath_thread_join(vmath_thread_t thread) { pthread_join(thread, NULL); }
    static void vmath_mutex_init(vmath_mutex_t* m) { pthread_mutex_init(m, NULL); }
    static void vmath_mutex_lock(vmath_mutex_t* m) { pthread_mutex_lock(m); }
    static void vmath_mutex_unlock(vmath_mutex_t* m) { pthread_mutex_unlock(m); }
    static void vmath_mutex_destroy(vmath_mutex_t* m) { pthread_mutex_destroy(m); }
    static void vmath_cond_init(vmath_cond_t* cv) { pthread_cond_init(cv, NULL); }
    static void vmath_cond_wait(vmath_cond_t* cv, vmath_mutex_t* m) { pthread_cond_wait(cv, m); }
    static void vmath_cond_broadcast(vmath_cond_t* cv) { pthread_cond_broadcast(cv); }
    static void vmath_cond_destroy(vmath_cond_t* cv) { pthread_cond_destroy(cv); }
#endif

// ========================================================
// THE OS-SLEEP THREAD POOL STATE (Physics Only Now!)
// ========================================================
#define NUM_WORKERS 4

vmath_mutex_t g_worker_mutex[NUM_WORKERS];
vmath_cond_t  g_worker_cv_start[NUM_WORKERS];
vmath_cond_t  g_worker_cv_done[NUM_WORKERS];
int g_worker_sig[NUM_WORKERS];
int g_worker_done[NUM_WORKERS];
vmath_thread_t g_worker_threads[NUM_WORKERS];

// ========================================================================
// CORE STRUCTS
// ========================================================================
typedef struct {
    float x, y, z;
    float yaw, pitch;
    float fov;
    float fwx, fwy, fwz;
    float rtx, rty, rtz;
    float upx, upy, upz;
} CameraState;
typedef struct {
    float *Obj_X, *Obj_Y, *Obj_Z, *Obj_Radius;
    float *Obj_FWX, *Obj_FWY, *Obj_FWZ;
    float *Obj_RTX, *Obj_RTY, *Obj_RTZ;
    float *Obj_UPX, *Obj_UPY, *Obj_UPZ;

    // Swarm Double Buffers
    float *Swarm_PX[2]; float *Swarm_PY[2]; float *Swarm_PZ[2];
    float *Swarm_VX[2]; float *Swarm_VY[2]; float *Swarm_VZ[2];
    int *Swarm_Indices[2];

    float *Swarm_Seed;
    int Swarm_State;
    float Swarm_GravityBlend;
    float Swarm_MetalBlend;
    float Swarm_ParadoxBlend;

    int *Swarm_TempIndices;
    float *Swarm_Distances;
    float *Swarm_TempDistances;
} RenderMemory;

// ========================================================
// THE UNIFIED PAYLOAD (Used by all 4 Workers)
// ========================================================

typedef struct {
    RenderMemory* mem;
    float time;
    float dt;
    int state;
    int push_active;
    int pull_active;
    int particle_count; // <--- ADD THIS!
} SwarmWorkerPayload;

SwarmWorkerPayload g_worker_payload;

// --- Vulkan AoS Structs & Pointers ---
// 16-byte aligned vector for perfect PCIe Write-Combining
typedef struct {
    float x, y, z;
    float padding;
} VertexAoS;

// Keep them static. They belong to vibemath's internal state.
static VertexAoS* g_gpu_vertex_buffer = NULL;
static uint32_t* g_gpu_index_buffer = NULL;

// GLOBALS
int       g_canvas_w;
int       g_canvas_h;
float     g_half_w;
float     g_half_h;
RenderMemory* g_mem ;
CameraState* g_cam;
int* g_queue;

EXPORT void vmath_bind_vulkan_buffers(VertexAoS* v_buf, uint32_t* i_buf) {
    g_gpu_vertex_buffer = v_buf;
    g_gpu_index_buffer = i_buf;
}

EXPORT void vmath_bind_engine(RenderMemory* mem, CameraState* cam, int* queue) {
    g_mem = mem; g_cam = cam; g_queue = queue;
}

// Notice how we removed the screen pointers! AVX2 no longer cares about rasterizing.
EXPORT void vmath_set_resolution(int w, int h, uint32_t* screen_ptr, float* z_buffer) {
    g_canvas_w = w; g_canvas_h = h; g_half_w = w * 0.5f; g_half_h = h * 0.5f;
}


// ========================================================================
// ALL PHYSICS KERNELS (Bundled into a collapsed region for brevity)
// ========================================================================
// ========================================================================
// FAST AVX2 TRIGONOMETRY (Minimax Approximations)
// ========================================================================
static inline __m256 wrap_pi_avx(__m256 x) {
    __m256 inv_two_pi = _mm256_set1_ps(1.0f / (2.0f * M_PI));
    __m256 two_pi = _mm256_set1_ps(2.0f * M_PI);
    __m256 q = _mm256_round_ps(_mm256_mul_ps(x, inv_two_pi), _MM_FROUND_TO_NEAREST_INT | _MM_FROUND_NO_EXC);
    return _mm256_fnmadd_ps(q, two_pi, x);
}
static inline __m256 fast_sin_avx(__m256 x) {
    x = wrap_pi_avx(x);
    __m256 B = _mm256_set1_ps(4.0f / M_PI), C = _mm256_set1_ps(-4.0f / (M_PI * M_PI));
    __m256 x_abs = _mm256_andnot_ps(_mm256_set1_ps(-0.0f), x);
    __m256 y = _mm256_fmadd_ps(_mm256_mul_ps(C, x_abs), x, _mm256_mul_ps(B, x));
    __m256 P = _mm256_set1_ps(0.225f);
    __m256 y_abs = _mm256_andnot_ps(_mm256_set1_ps(-0.0f), y);
    return _mm256_fmadd_ps(_mm256_fmadd_ps(y_abs, y, _mm256_sub_ps(_mm256_setzero_ps(), y)), P, y);
}
static inline __m256 fast_cos_avx(__m256 x) { return fast_sin_avx(_mm256_add_ps(x, _mm256_set1_ps(M_PI / 2.0f))); }
static inline __m256 fast_trig_noise_avx(__m256 nx, __m256 ny, __m256 nz, __m256 time) {
    __m256 v1 = fast_sin_avx(_mm256_add_ps(_mm256_mul_ps(nx, _mm256_set1_ps(3.1f)), time));
    __m256 v2 = fast_cos_avx(_mm256_add_ps(_mm256_mul_ps(ny, _mm256_set1_ps(2.8f)), time));
    __m256 v3 = fast_sin_avx(_mm256_add_ps(_mm256_mul_ps(nz, _mm256_set1_ps(3.4f)), time));
    __m256 out = _mm256_add_ps(v1, _mm256_add_ps(v2, v3));
    __m256 time2 = _mm256_mul_ps(time, _mm256_set1_ps(1.8f));
    __m256 v4 = fast_sin_avx(_mm256_add_ps(_mm256_mul_ps(nx, _mm256_set1_ps(7.2f)), time2));
    __m256 v5 = fast_cos_avx(_mm256_add_ps(_mm256_mul_ps(ny, _mm256_set1_ps(6.5f)), time2));
    __m256 v6 = fast_sin_avx(_mm256_add_ps(_mm256_mul_ps(nz, _mm256_set1_ps(8.1f)), time2));
    __m256 oct2 = _mm256_mul_ps(_mm256_add_ps(v4, _mm256_add_ps(v5, v6)), _mm256_set1_ps(0.35f));
    return _mm256_mul_ps(_mm256_add_ps(out, oct2), _mm256_set1_ps(0.25f));
}

// ... [KEEP ALL YOUR SWARM PHYSICS FUNCTIONS EXACTLY AS THEY WERE] ...
// Boilerplate Spring Physics Macro to keep the shape functions perfectly clean
#define APPLY_SPRING_PHYSICS() \
    __m256 v_px = _mm256_loadu_ps(&px[i]), v_py = _mm256_loadu_ps(&py[i]), v_pz = _mm256_loadu_ps(&pz[i]); \
    __m256 v_vx = _mm256_loadu_ps(&vx[i]), v_vy = _mm256_loadu_ps(&vy[i]), v_vz = _mm256_loadu_ps(&vz[i]); \
    v_vx = _mm256_mul_ps(_mm256_fmadd_ps(_mm256_sub_ps(v_tx, v_px), v_k, v_vx), v_damp); \
    v_vy = _mm256_mul_ps(_mm256_fmadd_ps(_mm256_sub_ps(v_ty, v_py), v_k, v_vy), v_damp); \
    v_vz = _mm256_mul_ps(_mm256_fmadd_ps(_mm256_sub_ps(v_tz, v_pz), v_k, v_vz), v_damp); \
    _mm256_storeu_ps(&px[i], _mm256_fmadd_ps(v_vx, v_dt, v_px)); \
    _mm256_storeu_ps(&py[i], _mm256_fmadd_ps(v_vy, v_dt, v_py)); \
    _mm256_storeu_ps(&pz[i], _mm256_fmadd_ps(v_vz, v_dt, v_pz)); \
    _mm256_storeu_ps(&vx[i], v_vx); _mm256_storeu_ps(&vy[i], v_vy); _mm256_storeu_ps(&vz[i], v_vz);

EXPORT void vmath_swarm_update_velocities(int count, float* px_in, float* py_in, float* pz_in, float* vx_in, float* vy_in, float* vz_in, float* px_out, float* py_out, float* pz_out, float* vx_out, float* vy_out, float* vz_out, float minX, float maxX, float minY, float maxY, float minZ, float maxZ, float dt, float gravity) {
    for (int i=0; i<count; i++) {
        float px = px_in[i], py = py_in[i], pz = pz_in[i]; float vx = vx_in[i], vy = vy_in[i], vz = vz_in[i];
        vy -= (gravity * dt); vx *= 0.995f; vy *= 0.995f; vz *= 0.995f;
        px += vx * dt; py += vy * dt; pz += vz * dt;
        if (px < minX) { px = minX; vx = fabsf(vx) * 0.8f; } else if (px > maxX) { px = maxX; vx = fabsf(vx) * -0.8f; }
        if (py < minY) { py = minY; vy = fabsf(vy) * 0.8f; } else if (py > maxY) { py = maxY; vy = fabsf(vy) * -0.8f; }
        if (pz < minZ) { pz = minZ; vz = fabsf(vz) * 0.8f; } else if (pz > maxZ) { pz = maxZ; vz = fabsf(vz) * -0.8f; }
        px_out[i] = px; py_out[i] = py; pz_out[i] = pz; vx_out[i] = vx; vy_out[i] = vy; vz_out[i] = vz;
    }
}
EXPORT void vmath_swarm_bundle(int count, float* px, float* py, float* pz, float* vx, float* vy, float* vz, float* seed, float cx, float cy, float cz, float time, float dt) {
    __m256 v_cx = _mm256_set1_ps(cx), v_cy = _mm256_set1_ps(cy), v_cz = _mm256_set1_ps(cz);
    __m256 v_r = _mm256_set1_ps(2000.0f + 400.0f * sinf(time * 6.0f));
    __m256 v_golden = _mm256_set1_ps(2.39996323f);
    __m256 v_1 = _mm256_set1_ps(1.0f), v_2 = _mm256_set1_ps(2.0f);
    __m256 v_dt = _mm256_set1_ps(dt), v_k = _mm256_set1_ps(4.0f * dt), v_damp = _mm256_set1_ps(0.92f);

    int i = 0; // <--- EXTRACTED FOR THE SCALAR TAIL!
    for (; i <= count - 8; i += 8) {
        __m256 v_s = _mm256_loadu_ps(&seed[i]);
        __m256 v_i = _mm256_set_ps(i+7, i+6, i+5, i+4, i+3, i+2, i+1, i);

        __m256 v_phi = _mm256_mul_ps(v_i, v_golden);

        // Math Hack: No acos needed! cos(theta) = 1-2s. sin(theta) = 2*sqrt(s*(1-s))
        __m256 v_cos_theta = _mm256_fnmadd_ps(v_2, v_s, v_1);
        __m256 v_sin_theta = _mm256_mul_ps(v_2, _mm256_sqrt_ps(_mm256_mul_ps(v_s, _mm256_sub_ps(v_1, v_s))));

        __m256 v_tx = _mm256_fmadd_ps(v_r, _mm256_mul_ps(v_sin_theta, fast_cos_avx(v_phi)), v_cx);
        __m256 v_ty = _mm256_fmadd_ps(v_r, v_cos_theta, v_cy);
        __m256 v_tz = _mm256_fmadd_ps(v_r, _mm256_mul_ps(v_sin_theta, fast_sin_avx(v_phi)), v_cz);

        APPLY_SPRING_PHYSICS();
    }
}

EXPORT void vmath_swarm_galaxy(int count, float* px, float* py, float* pz, float* vx, float* vy, float* vz, float* seed, float cx, float cy, float cz, float time, float dt) {
    __m256 v_cx = _mm256_set1_ps(cx), v_cy = _mm256_set1_ps(cy), v_cz = _mm256_set1_ps(cz);
    __m256 v_time_ang = _mm256_set1_ps(time * 1.5f), v_time_z = _mm256_set1_ps(time * 3.0f);
    __m256 v_dt = _mm256_set1_ps(dt), v_k = _mm256_set1_ps(4.0f * dt), v_damp = _mm256_set1_ps(0.92f);

    int i = 0;
    for (; i <= count - 8; i += 8) {
        __m256 v_s = _mm256_loadu_ps(&seed[i]);
        __m256 v_angle = _mm256_fmadd_ps(v_s, _mm256_set1_ps(3.14159f * 30.0f), v_time_ang);
        __m256 v_r = _mm256_fmadd_ps(v_s, _mm256_set1_ps(14000.0f), _mm256_set1_ps(1000.0f));

        __m256 v_tx = _mm256_fmadd_ps(v_r, fast_cos_avx(v_angle), v_cx);
        __m256 v_ty = _mm256_fmadd_ps(_mm256_set1_ps(800.0f), fast_sin_avx(_mm256_fnmadd_ps(v_time_z, _mm256_set1_ps(1.0f), _mm256_mul_ps(v_s, _mm256_set1_ps(40.0f)))), v_cy);
        __m256 v_tz = _mm256_fmadd_ps(v_r, fast_sin_avx(v_angle), v_cz);

        APPLY_SPRING_PHYSICS();
    }
}
EXPORT void vmath_swarm_tornado(int count, float* px, float* py, float* pz, float* vx, float* vy, float* vz, float* seed, float cx, float cy, float cz, float time, float dt) {
    __m256 v_cx = _mm256_set1_ps(cx), v_cy = _mm256_set1_ps(cy), v_cz = _mm256_set1_ps(cz);
    __m256 v_time_ang = _mm256_set1_ps(time * 4.0f);
    __m256 v_dt = _mm256_set1_ps(dt), v_k = _mm256_set1_ps(4.0f * dt), v_damp = _mm256_set1_ps(0.92f);

    int i = 0;
    for (; i <= count - 8; i += 8) {
        __m256 v_s = _mm256_loadu_ps(&seed[i]);
        __m256 v_height = _mm256_fnmadd_ps(_mm256_set1_ps(-24000.0f), v_s, _mm256_set1_ps(-12000.0f));
        __m256 v_angle = _mm256_fnmadd_ps(v_time_ang, _mm256_set1_ps(1.0f), _mm256_mul_ps(v_s, _mm256_set1_ps(3.14159f * 30.0f)));
        __m256 v_r = _mm256_fmadd_ps(v_s, _mm256_set1_ps(4000.0f), _mm256_set1_ps(2000.0f));

        __m256 v_tx = _mm256_fmadd_ps(v_r, fast_cos_avx(v_angle), v_cx);
        __m256 v_ty = _mm256_add_ps(v_cy, v_height);
        __m256 v_tz = _mm256_fmadd_ps(v_r, fast_sin_avx(v_angle), v_cz);

        APPLY_SPRING_PHYSICS();
    }
}
EXPORT void vmath_swarm_gyroscope(int count, float* px, float* py, float* pz, float* vx, float* vy, float* vz, float* seed, float cx, float cy, float cz, float time, float dt) {
    __m256 v_cx = _mm256_set1_ps(cx), v_cy = _mm256_set1_ps(cy), v_cz = _mm256_set1_ps(cz);
    __m256 v_r = _mm256_set1_ps(7000.0f);
    __m256 v_time_ang = _mm256_set1_ps(time * 2.5f);
    __m256 v_dt = _mm256_set1_ps(dt), v_k = _mm256_set1_ps(4.0f * dt), v_damp = _mm256_set1_ps(0.92f);

    int i = 0;
    for (; i <= count - 8; i += 8) {
        __m256 v_s = _mm256_loadu_ps(&seed[i]);
        __m256 v_angle = _mm256_fmadd_ps(v_s, _mm256_set1_ps(3.14159f * 2.0f), v_time_ang);

        __m256 v_cos = fast_cos_avx(v_angle);
        __m256 v_sin = fast_sin_avx(v_angle);

        // Calculate all 3 ring positions simultaneously!
        __m256 r0_x = _mm256_fmadd_ps(v_r, v_cos, v_cx), r0_y = _mm256_fmadd_ps(v_r, v_sin, v_cy), r0_z = v_cz;
        __m256 r1_x = r0_x, r1_y = v_cy, r1_z = _mm256_fmadd_ps(v_r, v_sin, v_cz);
        __m256 r2_x = v_cx, r2_y = _mm256_fmadd_ps(v_r, v_cos, v_cy), r2_z = r1_z;

        // Masking logic based on (i % 3)
        int rings[8] = { (i)%3, (i+1)%3, (i+2)%3, (i+3)%3, (i+4)%3, (i+5)%3, (i+6)%3, (i+7)%3 };
        __m256i v_ring = _mm256_loadu_si256((__m256i*)rings);

        __m256 m0 = _mm256_castsi256_ps(_mm256_cmpeq_epi32(v_ring, _mm256_setzero_si256()));
        __m256 m1 = _mm256_castsi256_ps(_mm256_cmpeq_epi32(v_ring, _mm256_set1_epi32(1)));

        __m256 v_tx = _mm256_blendv_ps(r2_x, _mm256_blendv_ps(r1_x, r0_x, m0), _mm256_or_ps(m0, m1));
        __m256 v_ty = _mm256_blendv_ps(r2_y, _mm256_blendv_ps(r1_y, r0_y, m0), _mm256_or_ps(m0, m1));
        __m256 v_tz = _mm256_blendv_ps(r2_z, _mm256_blendv_ps(r1_z, r0_z, m0), _mm256_or_ps(m0, m1));

        APPLY_SPRING_PHYSICS();
    }
}
EXPORT void vmath_swarm_metal(int count, float* px, float* py, float* pz, float* vx, float* vy, float* vz, float* seed, float cx, float cy, float cz, float time, float dt, float noise_blend) {
    __m256 v_cx = _mm256_set1_ps(cx), v_cy = _mm256_set1_ps(cy), v_cz = _mm256_set1_ps(cz);
    __m256 v_time = _mm256_set1_ps(time);
    __m256 v_blend = _mm256_set1_ps(noise_blend);
    __m256 v_radius = _mm256_set1_ps(4000.0f);
    __m256 v_max_disp = _mm256_set1_ps(3000.0f); // Max noise distortion

    __m256 v_dt = _mm256_set1_ps(dt);
    __m256 v_k = _mm256_set1_ps(4.0f * dt); // Spring stiffness
    __m256 v_damp = _mm256_set1_ps(0.92f);  // Friction

    int i = 0;
    // BLAST 8 PARTICLES PER CYCLE
    for (; i <= count - 8; i += 8) {
        __m256 v_s = _mm256_loadu_ps(&seed[i]);

        // 1. FAST SPHERICAL MAPPING (Fibonacci-style distribution without acos)
        // Z goes from 1.0 to -1.0 based on seed
        __m256 v_sz = _mm256_fnmadd_ps(v_s, _mm256_set1_ps(2.0f), _mm256_set1_ps(1.0f));
        // Radius at this Z: r_xy = sqrt(1.0 - z*z)
        __m256 v_rxy = _mm256_sqrt_ps(_mm256_fnmadd_ps(v_sz, v_sz, _mm256_set1_ps(1.0f)));
        // Phi rotates wildly based on seed
        __m256 v_phi = _mm256_mul_ps(v_s, _mm256_set1_ps(10000.0f));

        __m256 v_sx = _mm256_mul_ps(v_rxy, fast_cos_avx(v_phi));
        __m256 v_sy = _mm256_mul_ps(v_rxy, fast_sin_avx(v_phi));

        // 2. EVALUATE 4D NOISE AT THE NORMALS
        __m256 v_noise = fast_trig_noise_avx(v_sx, v_sy, v_sz, v_time);

        // 3. APPLY DISPLACEMENT (Using FMA to blend seamlessly!)
        // displacement = noise * noise_blend * max_disp
        __m256 v_disp = _mm256_mul_ps(v_noise, _mm256_mul_ps(v_blend, v_max_disp));

        // Target Pos = Center + Normal * (Radius + Displacement)
        __m256 v_final_r = _mm256_add_ps(v_radius, v_disp);
        __m256 v_tx = _mm256_fmadd_ps(v_sx, v_final_r, v_cx);
        __m256 v_ty = _mm256_fmadd_ps(v_sy, v_final_r, v_cy);
        __m256 v_tz = _mm256_fmadd_ps(v_sz, v_final_r, v_cz);

        // 4. SPRING PHYSICS (Pull current pos toward Target Pos)
        __m256 v_px = _mm256_loadu_ps(&px[i]);
        __m256 v_py = _mm256_loadu_ps(&py[i]);
        __m256 v_pz = _mm256_loadu_ps(&pz[i]);

        __m256 v_vx = _mm256_loadu_ps(&vx[i]);
        __m256 v_vy = _mm256_loadu_ps(&vy[i]);
        __m256 v_vz = _mm256_loadu_ps(&vz[i]);

        // v += (target - p) * k * dt; v *= damp;
        v_vx = _mm256_mul_ps(_mm256_fmadd_ps(_mm256_sub_ps(v_tx, v_px), v_k, v_vx), v_damp);
        v_vy = _mm256_mul_ps(_mm256_fmadd_ps(_mm256_sub_ps(v_ty, v_py), v_k, v_vy), v_damp);
        v_vz = _mm256_mul_ps(_mm256_fmadd_ps(_mm256_sub_ps(v_tz, v_pz), v_k, v_vz), v_damp);

        // p += v * dt;
        v_px = _mm256_fmadd_ps(v_vx, v_dt, v_px);
        v_py = _mm256_fmadd_ps(v_vy, v_dt, v_py);
        v_pz = _mm256_fmadd_ps(v_vz, v_dt, v_pz);

        _mm256_storeu_ps(&px[i], v_px);
        _mm256_storeu_ps(&py[i], v_py);
        _mm256_storeu_ps(&pz[i], v_pz);
        _mm256_storeu_ps(&vx[i], v_vx);
        _mm256_storeu_ps(&vy[i], v_vy);
        _mm256_storeu_ps(&vz[i], v_vz);
    }
}
EXPORT void vmath_swarm_smales(int count, float* px, float* py, float* pz, float* vx, float* vy, float* vz, float* seed, float cx, float cy, float cz, float time, float dt, float blend) {
    __m256 v_cx = _mm256_set1_ps(cx), v_cy = _mm256_set1_ps(cy), v_cz = _mm256_set1_ps(cz);
    __m256 v_base_radius = _mm256_set1_ps(4000.0f);

    // THE DOD BLENDING MATH (Calculated once outside the loop!)
    // If blend=0: eversion=1.0, bulge=0.0
    // If blend=1: eversion=cos(t), bulge=sin(t)
    float t_scaled = time * 1.5f;
    float eversion_scalar = 1.0f + blend * (cosf(t_scaled) - 1.0f);
    float bulge_scalar = blend * sinf(t_scaled);

    __m256 v_eversion = _mm256_set1_ps(eversion_scalar);
    __m256 v_bulge = _mm256_set1_ps(bulge_scalar);

    __m256 v_1_2 = _mm256_set1_ps(1.2f);
    __m256 v_0_5 = _mm256_set1_ps(0.5f);
    __m256 v_4_0 = _mm256_set1_ps(4.0f);
    __m256 v_2_0 = _mm256_set1_ps(2.0f);
    __m256 v_3_0 = _mm256_set1_ps(3.0f);
    __m256 v_pi = _mm256_set1_ps(M_PI);
    __m256 v_phi_mul = _mm256_set1_ps(M_PI * 2.0f * 100.0f); // Wrap phi around 100 times

    __m256 v_dt = _mm256_set1_ps(dt);
    __m256 v_k = _mm256_set1_ps(4.0f * dt);
    __m256 v_damp = _mm256_set1_ps(0.92f);

    int i = 0;
    for (; i <= count - 8; i += 8) {
        __m256 v_s = _mm256_loadu_ps(&seed[i]);

        // 1. Map seed to Theta [0, PI] and Phi [0, 2PI * 100]
        __m256 v_theta = _mm256_mul_ps(v_s, v_pi);
        __m256 v_phi = _mm256_mul_ps(v_s, v_phi_mul);

        __m256 v_ny = fast_cos_avx(v_theta);
        __m256 v_sin_theta = fast_sin_avx(v_theta);

        __m256 v_nx = _mm256_mul_ps(v_sin_theta, fast_cos_avx(v_phi));
        __m256 v_nz = _mm256_mul_ps(v_sin_theta, fast_sin_avx(v_phi));

        // 2. PARADOX MATH
        __m256 v_waves = fast_cos_avx(_mm256_mul_ps(v_phi, v_4_0));
        __m256 v_twist = fast_sin_avx(_mm256_mul_ps(v_theta, v_2_0));

        __m256 v_r_corr = _mm256_mul_ps(v_base_radius,
                          _mm256_mul_ps(v_bulge,
                          _mm256_mul_ps(v_waves,
                          _mm256_mul_ps(v_twist, v_1_2))));

        __m256 v_r_main = _mm256_mul_ps(v_base_radius, v_eversion);

        // 3. APPLY DISPLACEMENT
        __m256 v_tx = _mm256_fmadd_ps(v_nx, _mm256_add_ps(v_r_main, v_r_corr), v_cx);
        __m256 v_tz = _mm256_fmadd_ps(v_nz, _mm256_add_ps(v_r_main, v_r_corr), v_cz);

        __m256 v_ty_offset = _mm256_mul_ps(fast_cos_avx(_mm256_mul_ps(v_theta, v_3_0)),
                             _mm256_mul_ps(v_base_radius,
                             _mm256_mul_ps(v_bulge, v_0_5)));

        __m256 v_ty = _mm256_add_ps(v_cy, _mm256_fmadd_ps(v_ny, v_r_main, v_ty_offset));

        // 4. SPRING PHYSICS
        __m256 v_px = _mm256_loadu_ps(&px[i]);
        __m256 v_py = _mm256_loadu_ps(&py[i]);
        __m256 v_pz = _mm256_loadu_ps(&pz[i]);

        __m256 v_vx = _mm256_loadu_ps(&vx[i]);
        __m256 v_vy = _mm256_loadu_ps(&vy[i]);
        __m256 v_vz = _mm256_loadu_ps(&vz[i]);

        v_vx = _mm256_mul_ps(_mm256_fmadd_ps(_mm256_sub_ps(v_tx, v_px), v_k, v_vx), v_damp);
        v_vy = _mm256_mul_ps(_mm256_fmadd_ps(_mm256_sub_ps(v_ty, v_py), v_k, v_vy), v_damp);
        v_vz = _mm256_mul_ps(_mm256_fmadd_ps(_mm256_sub_ps(v_tz, v_pz), v_k, v_vz), v_damp);

        v_px = _mm256_fmadd_ps(v_vx, v_dt, v_px);
        v_py = _mm256_fmadd_ps(v_vy, v_dt, v_py);
        v_pz = _mm256_fmadd_ps(v_vz, v_dt, v_pz);

        _mm256_storeu_ps(&px[i], v_px);
        _mm256_storeu_ps(&py[i], v_py);
        _mm256_storeu_ps(&pz[i], v_pz);
        _mm256_storeu_ps(&vx[i], v_vx);
        _mm256_storeu_ps(&vy[i], v_vy);
        _mm256_storeu_ps(&vz[i], v_vz);
    }
}
EXPORT void vmath_swarm_apply_explosion(int count, float* px, float* py, float* pz, float* vx, float* vy, float* vz, float ex, float ey, float ez, float force, float radius) {
    __m256 v_ex = _mm256_set1_ps(ex), v_ey = _mm256_set1_ps(ey), v_ez = _mm256_set1_ps(ez);
    __m256 v_r2 = _mm256_set1_ps(radius * radius);
    __m256 v_1 = _mm256_set1_ps(1.0f);
    __m256 v_force = _mm256_set1_ps(force);
    __m256 v_inv_radius = _mm256_set1_ps(1.0f / radius);

    int i = 0; // <--- EXTRACTED SO IT SURVIVES FOR THE SCALAR LOOP!
    for (; i <= count - 8; i += 8) {
        __m256 dx = _mm256_sub_ps(_mm256_loadu_ps(&px[i]), v_ex);
        __m256 dy = _mm256_sub_ps(_mm256_loadu_ps(&py[i]), v_ey);
        __m256 dz = _mm256_sub_ps(_mm256_loadu_ps(&pz[i]), v_ez);

        __m256 dist2 = _mm256_fmadd_ps(dz, dz, _mm256_fmadd_ps(dy, dy, _mm256_mul_ps(dx, dx)));

        // Mask: 1.0f < dist2 < r2
        __m256 mask = _mm256_and_ps(_mm256_cmp_ps(dist2, v_r2, _CMP_LT_OQ), _mm256_cmp_ps(dist2, v_1, _CMP_GT_OQ));

        if (!_mm256_testz_ps(mask, mask)) {
            __m256 inv_dist = _mm256_rsqrt_ps(dist2); // Fast hardware inverse square root
            __m256 dist = _mm256_mul_ps(dist2, inv_dist);

            // f = force * (1.0f - dist * inv_radius)
            __m256 f = _mm256_mul_ps(v_force, _mm256_sub_ps(v_1, _mm256_mul_ps(dist, v_inv_radius)));
            __m256 f_inv_dist = _mm256_mul_ps(f, inv_dist); // (f / dist)

            __m256 v_vx = _mm256_loadu_ps(&vx[i]);
            __m256 v_vy = _mm256_loadu_ps(&vy[i]);
            __m256 v_vz = _mm256_loadu_ps(&vz[i]);

            v_vx = _mm256_blendv_ps(v_vx, _mm256_fmadd_ps(dx, f_inv_dist, v_vx), mask);
            v_vy = _mm256_blendv_ps(v_vy, _mm256_fmadd_ps(dy, f_inv_dist, v_vy), mask);
            v_vz = _mm256_blendv_ps(v_vz, _mm256_fmadd_ps(dz, f_inv_dist, v_vz), mask);

            _mm256_storeu_ps(&vx[i], v_vx);
            _mm256_storeu_ps(&vy[i], v_vy);
            _mm256_storeu_ps(&vz[i], v_vz);
        }
    }
}
EXPORT void vmath_swarm_sort_depth(int count, float* px, float* py, float* pz, int* indices, int* temp_indices, float* distances, float* temp_distances, float cx, float cy, float cz) {
    for(int j = 0; j < count; j++) indices[j] = j;
}
// The bare-metal PRNG
static inline float fast_xorshift_float(uint32_t* state) {
    *state ^= *state << 13;
    *state ^= *state >> 17;
    *state ^= *state << 5;
    return (float)(*state & 0xFFFFFF) / 16777215.0f;
}

// The Dedicated Bootloader
EXPORT void vmath_seed_swarm(int particle_count) {
    if (!g_mem || particle_count <= 0) return;

    RenderMemory* mem = g_mem;
    uint32_t rng_state = 1337; // The master universe seed

    // A single C core will rip through this loop in roughly ~3ms
    for (int i = 0; i < particle_count; i++) {
        mem->Swarm_PX[0][i] = (fast_xorshift_float(&rng_state) - 0.5f) * 20000.0f;
        mem->Swarm_PY[0][i] = (fast_xorshift_float(&rng_state) - 0.5f) * 10000.0f + 5000.0f;
        mem->Swarm_PZ[0][i] = (fast_xorshift_float(&rng_state) - 0.5f) * 20000.0f;

        mem->Swarm_VX[0][i] = (fast_xorshift_float(&rng_state) - 0.5f) * 5000.0f;
        mem->Swarm_VY[0][i] = (fast_xorshift_float(&rng_state) - 0.5f) * 5000.0f;
        mem->Swarm_VZ[0][i] = (fast_xorshift_float(&rng_state) - 0.5f) * 5000.0f;

        mem->Swarm_Seed[i] = (float)i / (float)(particle_count - 1);
    }
}
THREAD_FUNC vmath_swarm_worker(void* arg) {
    int t_id = (int)(intptr_t)arg;
    float jblow_thread_id = (float)t_id;
    SwarmWorkerPayload* p = &g_worker_payload;

    while (1) {
        // 1. SLEEP UNTIL SIGNALED
        vmath_mutex_lock(&g_worker_mutex[t_id]);
        while (g_worker_sig[t_id] == 0) {
            vmath_cond_wait(&g_worker_cv_start[t_id], &g_worker_mutex[t_id]);
        }
        if (g_worker_sig[t_id] == 2) {
            vmath_mutex_unlock(&g_worker_mutex[t_id]);
            break;
        }
        vmath_mutex_unlock(&g_worker_mutex[t_id]);

        RenderMemory* mem = p->mem;
        float c_time = p->time;
        float c_dt = p->dt;

        // 2. THE PURE HOT LOOP
        if (g_gpu_vertex_buffer && mem && p->particle_count > 0) {
            int total_particles = p->particle_count;
            int chunk_size = total_particles / NUM_WORKERS;

            int start_idx = t_id * chunk_size;
            int end_idx = (t_id == NUM_WORKERS - 1) ? total_particles : start_idx + chunk_size;
            int chunk_count = end_idx - start_idx;
            float size = 20.0f;

            // ... Your Phase 1 Physics and Phase 2 Translation goes here! ...
            // ==========================================
            // PHASE 1: PHYSICS HOT LOOP (Queue Annihilated)
            // ==========================================
            // Always apply base velocities first
            vmath_swarm_update_velocities(chunk_count,
                mem->Swarm_PX[0] + start_idx, mem->Swarm_PY[0] + start_idx, mem->Swarm_PZ[0] + start_idx,
                mem->Swarm_VX[0] + start_idx, mem->Swarm_VY[0] + start_idx, mem->Swarm_VZ[0] + start_idx,
                mem->Swarm_PX[0] + start_idx, mem->Swarm_PY[0] + start_idx, mem->Swarm_PZ[0] + start_idx,
                mem->Swarm_VX[0] + start_idx, mem->Swarm_VY[0] + start_idx, mem->Swarm_VZ[0] + start_idx,
                -15000*CAGE_FACTOR, 15000*CAGE_FACTOR, -4000*CAGE_FACTOR, 15000*CAGE_FACTOR, -15000*CAGE_FACTOR, 15000*CAGE_FACTOR, c_dt, -8000.0f * mem->Swarm_GravityBlend);

            // Handle Mouse Explosions
            if (p->push_active) {
                vmath_swarm_apply_explosion(chunk_count, mem->Swarm_PX[0] + start_idx, mem->Swarm_PY[0] + start_idx, mem->Swarm_PZ[0] + start_idx, mem->Swarm_VX[0] + start_idx, mem->Swarm_VY[0] + start_idx, mem->Swarm_VZ[0] + start_idx, 0, 5000, 0, 5000000.0f * c_dt, 15000.0f);
            }
            if (p->pull_active) {
                vmath_swarm_apply_explosion(chunk_count, mem->Swarm_PX[0] + start_idx, mem->Swarm_PY[0] + start_idx, mem->Swarm_PZ[0] + start_idx, mem->Swarm_VX[0] + start_idx, mem->Swarm_VY[0] + start_idx, mem->Swarm_VZ[0] + start_idx, 0, 5000, 0, -4000000.0f * c_dt, 20000.0f);
            }

            // Handle Swarm Formations
            switch (p->state) {
                case 1: vmath_swarm_bundle(chunk_count, mem->Swarm_PX[0] + start_idx, mem->Swarm_PY[0] + start_idx, mem->Swarm_PZ[0] + start_idx, mem->Swarm_VX[0] + start_idx, mem->Swarm_VY[0] + start_idx, mem->Swarm_VZ[0] + start_idx, mem->Swarm_Seed + start_idx, 0, 5000, 0, c_time, c_dt); break;
                case 2: vmath_swarm_galaxy(chunk_count, mem->Swarm_PX[0] + start_idx, mem->Swarm_PY[0] + start_idx, mem->Swarm_PZ[0] + start_idx, mem->Swarm_VX[0] + start_idx, mem->Swarm_VY[0] + start_idx, mem->Swarm_VZ[0] + start_idx, mem->Swarm_Seed + start_idx, 0, 5000, 0, c_time, c_dt); break;
                case 3: vmath_swarm_tornado(chunk_count, mem->Swarm_PX[0] + start_idx, mem->Swarm_PY[0] + start_idx, mem->Swarm_PZ[0] + start_idx, mem->Swarm_VX[0] + start_idx, mem->Swarm_VY[0] + start_idx, mem->Swarm_VZ[0] + start_idx, mem->Swarm_Seed + start_idx, 0, 5000, 0, c_time, c_dt); break;
                case 4: vmath_swarm_gyroscope(chunk_count, mem->Swarm_PX[0] + start_idx, mem->Swarm_PY[0] + start_idx, mem->Swarm_PZ[0] + start_idx, mem->Swarm_VX[0] + start_idx, mem->Swarm_VY[0] + start_idx, mem->Swarm_VZ[0] + start_idx, mem->Swarm_Seed + start_idx, 0, 5000, 0, c_time, c_dt); break;
                case 5: vmath_swarm_metal(chunk_count, mem->Swarm_PX[0] + start_idx, mem->Swarm_PY[0] + start_idx, mem->Swarm_PZ[0] + start_idx, mem->Swarm_VX[0] + start_idx, mem->Swarm_VY[0] + start_idx, mem->Swarm_VZ[0] + start_idx, mem->Swarm_Seed + start_idx, 0, 5000, 0, c_time, c_dt, mem->Swarm_MetalBlend); break;
                case 6: vmath_swarm_smales(chunk_count, mem->Swarm_PX[0] + start_idx, mem->Swarm_PY[0] + start_idx, mem->Swarm_PZ[0] + start_idx, mem->Swarm_VX[0] + start_idx, mem->Swarm_VY[0] + start_idx, mem->Swarm_VZ[0] + start_idx, mem->Swarm_Seed + start_idx, 0, 5000, 0, c_time, c_dt, mem->Swarm_ParadoxBlend); break;
            }
            // ==========================================
            // PHASE 2: TRANSLATION HOT LOOP (The Pro Version)
            // ==========================================
            for (int i = start_idx; i < end_idx; i++) {
                // Just write the center once. The GPU handles the "expansion" into 12 vertices.
                g_gpu_vertex_buffer[i] = (VertexAoS){ 
                    mem->Swarm_PX[0][i], 
                    mem->Swarm_PY[0][i], 
                    mem->Swarm_PZ[0][i], 
                    jblow_thread_id 
                };
            }
        }

        // 3. SIGNAL DONE
        vmath_mutex_lock(&g_worker_mutex[t_id]);
        g_worker_sig[t_id] = 0;
        g_worker_done[t_id] = 1;
        vmath_cond_broadcast(&g_worker_cv_done[t_id]);
        vmath_mutex_unlock(&g_worker_mutex[t_id]);
    }
    return THREAD_RETURN_VAL;
}

EXPORT void vmath_step_swarm(int particle_count, float time, float dt, int state, int push_active, int pull_active) {
    if (!g_mem) return;

    // 1. SETUP CLEAN PAYLOAD
    g_worker_payload.mem = g_mem;
    g_worker_payload.particle_count = particle_count; // Store it!
    g_worker_payload.time = time;
    g_worker_payload.dt = dt;
    g_worker_payload.state = state;
    g_worker_payload.push_active = push_active;
    g_worker_payload.pull_active = pull_active;

    // 2. WAKE UP ALL 4 WORKERS
    for (int b = 0; b < NUM_WORKERS; b++) {
        vmath_mutex_lock(&g_worker_mutex[b]);
        g_worker_done[b] = 0;
        g_worker_sig[b] = 1;
        vmath_cond_broadcast(&g_worker_cv_start[b]);
        vmath_mutex_unlock(&g_worker_mutex[b]);
    }

    // 3. WAIT FOR ALL 4 WORKERS TO FINISH
    for (int b = 0; b < NUM_WORKERS; b++) {
        vmath_mutex_lock(&g_worker_mutex[b]);
        while (g_worker_done[b] == 0) {
            vmath_cond_wait(&g_worker_cv_done[b], &g_worker_mutex[b]);
        }
        vmath_mutex_unlock(&g_worker_mutex[b]);
    }
}

EXPORT void vmath_init_thread_pool() {
    for (int i = 0; i < NUM_WORKERS; i++) {
        vmath_mutex_init(&g_worker_mutex[i]);
        vmath_cond_init(&g_worker_cv_start[i]);
        vmath_cond_init(&g_worker_cv_done[i]);

        g_worker_sig[i] = 0;
        g_worker_done[i] = 1; // Start in 'done' state so the main thread doesn't wait

        // Boot the thread and hand it its specific ID
        g_worker_threads[i] = vmath_thread_start(vmath_swarm_worker, (void*)(intptr_t)i);
    }
}
EXPORT void vmath_shutdown_thread_pool() {
    for (int i = 0; i < NUM_WORKERS; i++) {
        // Send the kill signal
        vmath_mutex_lock(&g_worker_mutex[i]);
        g_worker_sig[i] = 2;
        vmath_cond_broadcast(&g_worker_cv_start[i]);
        vmath_mutex_unlock(&g_worker_mutex[i]);

        // Wait for the thread to finish its current loop and exit
        vmath_thread_join(g_worker_threads[i]);

        // Clean up OS resources
        vmath_mutex_destroy(&g_worker_mutex[i]);
        vmath_cond_destroy(&g_worker_cv_start[i]);
        vmath_cond_destroy(&g_worker_cv_done[i]);
    }
}
