#include "FlexApi.h"
#include "FlexSolver.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <functional>
#include <malloc.h>
#include <mutex>
#include <thread>
#include <unordered_map>
#include <vector>

namespace kf2vr::flex {
namespace {
std::atomic<LogFunction> logFunction{nullptr};

struct SolverHandle {
    explicit SolverHandle(int maxParticles):solver(maxParticles) {}
    Solver solver;
    bool running=false;                       // guarded by gate
    std::vector<std::function<void()>> deferred; // host copies queued behind an update
    std::atomic<int> activeCount{0};
};

struct Job { SolverHandle* handle; float dt; int substeps; };

// One worker owns every in-flight update; FleX's single CUDA stream had the
// same ordering. Parallel loops inside an update use the system thread pool.
std::mutex gate;
std::condition_variable changed;
std::deque<Job> queue;
int pending=0;
std::thread worker;
bool workerStarted=false;
std::atomic<int> solverCount{0},containerCount{0};
std::atomic<double> lastUpdateMs{0};

void WorkerLoop() {
    for(;;) {
        Job job;
        {
            std::unique_lock lock(gate);
            changed.wait(lock,[]{ return !queue.empty(); });
            job=queue.front(); queue.pop_front();
        }
        const auto start=std::chrono::steady_clock::now();
        try { job.handle->solver.Update(job.dt,job.substeps); }
        catch(...) { Log("FlexPortable update failed; particles keep their last state"); }
        lastUpdateMs.store(std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count());
        for(;;) {
            std::vector<std::function<void()>> work;
            {
                std::lock_guard lock(gate);
                if(job.handle->deferred.empty()) { job.handle->running=false; --pending; break; }
                work.swap(job.handle->deferred);
            }
            for(auto& item:work) item();
        }
        changed.notify_all();
    }
}

void EnsureWorker() {
    std::lock_guard lock(gate);
    if(workerStarted) return;
    worker=std::thread(WorkerLoop);
    worker.detach(); // lives until process exit, like the game's other engine threads
    workerStarted=true;
}

void WaitIdle(SolverHandle* handle) {
    std::unique_lock lock(gate);
    changed.wait(lock,[&]{ return !handle->running; });
}

// Copies out of the solver run after any in-flight update, as an async
// cudaMemcpy queued behind the update kernels would.
template<class Fn> void ReadAfterUpdate(SolverHandle* handle,Fn&& fn) {
    {
        std::lock_guard lock(gate);
        if(handle->running) { handle->deferred.emplace_back(std::forward<Fn>(fn)); return; }
    }
    fn();
}

SolverHandle* Handle(void* solver) { return static_cast<SolverHandle*>(solver); }

// ---- flexRelease_x64.dll ------------------------------------------------------------
int __cdecl FlexInit(int version,ErrorCallback,int) {
    if(version!=Version) { Log("FlexPortable refused header version %d",version); return 1; }
    EnsureWorker();
    Log("FlexPortable revision=1 initialized; CPU position-based solver, vendor-independent");
    return 0;
}
void __cdecl FlexShutdown() {
    std::unique_lock lock(gate);
    changed.wait(lock,[]{ return pending==0; });
}
void* __cdecl FlexAlloc(int size) {
    if(size<=0) size=16;
    void* memory=_aligned_malloc(static_cast<std::size_t>(size),64);
    if(memory) std::memset(memory,0,static_cast<std::size_t>(size));
    return memory;
}
void __cdecl FlexFree(void* memory) { if(memory) _aligned_free(memory); }
void* __cdecl FlexCreateSolver(int maxParticles,int,int) {
    try {
        auto* handle=new SolverHandle(maxParticles);
        ++solverCount;
        Log("FlexPortable solver created maxParticles=%d",handle->solver.MaxParticles());
        return handle;
    } catch(...) { Log("FlexPortable solver allocation failed maxParticles=%d",maxParticles); return nullptr; }
}
void __cdecl FlexDestroySolver(void* solver) {
    if(!solver) return;
    WaitIdle(Handle(solver));
    delete Handle(solver);
    --solverCount;
}
void __cdecl FlexUpdateSolver(void* solver,float dt,int substeps,void*) {
    if(!solver) return;
    auto* handle=Handle(solver);
    WaitIdle(handle);
    std::lock_guard lock(gate);
    handle->running=true; ++pending;
    queue.push_back({handle,dt,substeps});
    changed.notify_all();
}
void __cdecl FlexSetParams(void* solver,const Params* params) {
    if(!solver || !params) return;
    WaitIdle(Handle(solver)); Handle(solver)->solver.SetParams(*params);
}
void __cdecl FlexSetActive(void* solver,const int* indices,int count,int) {
    if(!solver) return;
    WaitIdle(Handle(solver));
    Handle(solver)->solver.SetActive(indices,count);
    Handle(solver)->activeCount.store(Handle(solver)->solver.ActiveCount());
}
void __cdecl FlexGetActive(void* solver,int* indices,int) {
    if(!solver) return;
    ReadAfterUpdate(Handle(solver),[=]{ Handle(solver)->solver.GetActive(indices); });
}
int __cdecl FlexGetActiveCount(void* solver) { return solver?Handle(solver)->activeCount.load():0; }
void __cdecl FlexSetParticles(void* solver,const float* data,int count,int) {
    if(!solver) return;
    WaitIdle(Handle(solver)); Handle(solver)->solver.SetParticles(data,count);
}
void __cdecl FlexGetParticles(void* solver,float* data,int count,int) {
    if(!solver) return;
    ReadAfterUpdate(Handle(solver),[=]{ Handle(solver)->solver.GetParticles(data,count); });
}
void __cdecl FlexSetVelocities(void* solver,const float* data,int count,int) {
    if(!solver) return;
    WaitIdle(Handle(solver)); Handle(solver)->solver.SetVelocities(data,count);
}
void __cdecl FlexGetVelocities(void* solver,float* data,int count,int) {
    if(!solver) return;
    ReadAfterUpdate(Handle(solver),[=]{ Handle(solver)->solver.GetVelocities(data,count); });
}
void __cdecl FlexSetPhases(void* solver,const int* data,int count,int) {
    if(!solver) return;
    WaitIdle(Handle(solver)); Handle(solver)->solver.SetPhases(data,count);
}
void __cdecl FlexGetPhases(void* solver,int* data,int count,int) {
    if(!solver) return;
    ReadAfterUpdate(Handle(solver),[=]{ Handle(solver)->solver.GetPhases(data,count); });
}
void __cdecl FlexSetNormals(void* solver,const float* data,int count,int) {
    if(!solver) return;
    WaitIdle(Handle(solver)); Handle(solver)->solver.SetNormals(data,count);
}
void __cdecl FlexGetNormals(void* solver,float* data,int count,int) {
    if(!solver) return;
    ReadAfterUpdate(Handle(solver),[=]{ Handle(solver)->solver.GetNormals(data,count); });
}
void __cdecl FlexGetDensities(void* solver,float* data,int) {
    if(!solver) return;
    ReadAfterUpdate(Handle(solver),[=]{ Handle(solver)->solver.GetDensities(data,Handle(solver)->solver.MaxParticles()); });
}
void __cdecl FlexGetBounds(void* solver,float* lower,float* upper,int) {
    if(!solver) return;
    ReadAfterUpdate(Handle(solver),[=]{ Handle(solver)->solver.GetBounds(lower,upper); });
}
void __cdecl FlexSetConvexes(void* solver,const float* aabbMin,const float* aabbMax,const int* planeOffsets,
    const int* planeCounts,const float* planes,const float* positions,const float* rotations,const int* flags,
    int convexCount,int planeCount,int) {
    if(!solver) return;
    WaitIdle(Handle(solver));
    Handle(solver)->solver.SetConvexes(aabbMin,aabbMax,planeOffsets,planeCounts,planes,positions,rotations,flags,convexCount,planeCount);
}
void __cdecl FlexSetTrianglesAdvanced(void* solver,const float* vertices,int triangleCount,int vertexCount,
    const float*,const float*,float cellSize,int,int) {
    if(!solver) return;
    WaitIdle(Handle(solver));
    Handle(solver)->solver.SetTriangles(vertices,std::min(triangleCount,vertexCount/3),cellSize);
}
void __cdecl FlexSetForceFields(void* solver,const ForceField* fields,int count,int) {
    if(!solver) return;
    WaitIdle(Handle(solver)); Handle(solver)->solver.SetForceFields(fields,count);
}
void __cdecl FlexSetFence() {}
void __cdecl FlexWaitFence() {
    std::unique_lock lock(gate);
    changed.wait(lock,[]{ return pending==0; });
}
void __cdecl FlexStartRecord(void*,const char*) {}
void __cdecl FlexStopRecord(void*) {}

// ---- flexExtRelease_x64.dll ---------------------------------------------------------
struct InstanceState { std::array<float,4> rotation{0,0,0,1}; float translation[3]{}; };

struct Container {
    SolverHandle* handle=nullptr;
    int maxParticles=0;
    std::vector<int> freeList;
    std::vector<ExtInstance*> instances;
    std::unordered_map<ExtInstance*,InstanceState> state;
    float* particles=nullptr;   // x,y,z,invMass
    float* velocities=nullptr;  // x,y,z
    int* phases=nullptr;
    float* normals=nullptr;     // x,y,z,w
    int* activeScratch=nullptr;
    std::vector<float> rotations,translations; // per rigid: 3x3 column-major, xyz
    bool activeDirty=true,shapesDirty=true;
};

int GetActiveList(Container* c,int* out) {
    std::vector<std::uint8_t> isFree(c->maxParticles,0);
    for(int i:c->freeList) if(i>=0 && i<c->maxParticles) isFree[i]=1;
    int n=0;
    for(int i=0;i<c->maxParticles;++i) if(!isFree[i]) out[n++]=i;
    return n;
}

void* __cdecl ExtCreateContainer(void* solver,int maxParticles) {
    if(!solver || maxParticles<=0) return nullptr;
    auto* c=new Container();
    c->handle=Handle(solver);
    c->maxParticles=std::min(maxParticles,c->handle->solver.MaxParticles());
    c->freeList.resize(c->maxParticles);
    for(int i=0;i<c->maxParticles;++i) c->freeList[i]=i;
    c->particles=static_cast<float*>(FlexAlloc(16*c->maxParticles));
    c->velocities=static_cast<float*>(FlexAlloc(12*c->maxParticles));
    c->phases=static_cast<int*>(FlexAlloc(4*c->maxParticles));
    c->normals=static_cast<float*>(FlexAlloc(16*c->maxParticles));
    c->activeScratch=static_cast<int*>(FlexAlloc(4*c->maxParticles));
    ++containerCount;
    return c;
}
void __cdecl ExtDestroyContainer(void* container) {
    auto* c=static_cast<Container*>(container);
    if(!c) return;
    WaitIdle(c->handle);
    for(auto* instance:c->instances) { std::free(instance->particleIndices); delete instance; }
    FlexFree(c->particles); FlexFree(c->velocities); FlexFree(c->phases); FlexFree(c->normals); FlexFree(c->activeScratch);
    delete c;
    --containerCount;
}
int __cdecl ExtAllocParticles(void* container,int count,int* indices) {
    auto* c=static_cast<Container*>(container);
    if(!c || !indices) return 0;
    count=std::clamp(count,0,static_cast<int>(c->freeList.size()));
    const auto first=c->freeList.size()-count;
    std::copy(c->freeList.begin()+first,c->freeList.end(),indices);
    c->freeList.resize(first);
    c->activeDirty=true;
    return count;
}
void __cdecl ExtFreeParticles(void* container,int count,const int* indices) {
    auto* c=static_cast<Container*>(container);
    if(!c || !indices || count<=0) return;
    c->freeList.insert(c->freeList.end(),indices,indices+count);
    c->activeDirty=true;
}
int __cdecl ExtGetActiveList(void* container,int* indices) {
    auto* c=static_cast<Container*>(container);
    return c && indices?GetActiveList(c,indices):0;
}
void __cdecl ExtGetParticleData(void* container,float** particles,float** velocities,int** phases,float** normals) {
    auto* c=static_cast<Container*>(container);
    if(!c) return;
    if(particles) *particles=c->particles;
    if(velocities) *velocities=c->velocities;
    if(phases) *phases=c->phases;
    if(normals) *normals=c->normals;
}
void __cdecl ExtGetRigidData(void* container,float** rotations,float** translations) {
    auto* c=static_cast<Container*>(container);
    if(!c) return;
    if(rotations && !c->rotations.empty()) *rotations=c->rotations.data();
    if(translations && !c->translations.empty()) *translations=c->translations.data();
}
void __cdecl ExtGetTriangleData(void*,int**,float**) {}

void* __cdecl ExtAddObject(void* container,const ExtAsset* asset,const float* transform,float vx,float vy,float vz,int phase) {
    auto* c=static_cast<Container*>(container);
    if(!c || !asset || !transform || asset->numParticles<=0 || !asset->particles) return nullptr;
    const int n=asset->numParticles;
    if(n>static_cast<int>(c->freeList.size())) return nullptr;
    auto* instance=new ExtInstance{};
    instance->particleIndices=static_cast<std::int32_t*>(std::malloc(sizeof(std::int32_t)*n));
    instance->numParticles=n;
    instance->triangleIndex=-1; instance->rigidIndex=-1; instance->inflatableIndex=-1;
    instance->asset=asset;
    std::memcpy(instance->transform,transform,sizeof(instance->transform));
    ExtAllocParticles(c,n,instance->particleIndices);
    const float* m=transform; // column-major 4x4
    for(int k=0;k<n;++k) {
        const int i=instance->particleIndices[k];
        const float* p=asset->particles+4*k;
        float* out=c->particles+4*i;
        out[0]=m[0]*p[0]+m[4]*p[1]+m[8]*p[2]+m[12];
        out[1]=m[1]*p[0]+m[5]*p[1]+m[9]*p[2]+m[13];
        out[2]=m[2]*p[0]+m[6]*p[1]+m[10]*p[2]+m[14];
        out[3]=p[3];
        c->velocities[3*i]=vx; c->velocities[3*i+1]=vy; c->velocities[3*i+2]=vz;
        c->phases[i]=(asset->phases?asset->phases[k]:0)+phase;
        std::memset(c->normals+4*i,0,16);
    }
    InstanceState initial;
    float basis[9];
    for(int col=0;col<3;++col) {
        const float x=m[4*col],y=m[4*col+1],z=m[4*col+2];
        const float length=std::sqrt(x*x+y*y+z*z);
        const float inv=length>1e-12f?1.0f/length:0.0f;
        basis[3*col]=x*inv; basis[3*col+1]=y*inv; basis[3*col+2]=z*inv;
    }
    initial.rotation=QuaternionFromMatrix(basis);
    const float* centre=asset->rigidCenter;
    for(int a=0;a<3;++a) initial.translation[a]=m[a]*centre[0]+m[4+a]*centre[1]+m[8+a]*centre[2]+m[12+a];
    c->state[instance]=initial;
    c->instances.push_back(instance);
    c->shapesDirty=true;
    return instance;
}
void __cdecl ExtRemoveObject(void* container,ExtInstance* instance) {
    auto* c=static_cast<Container*>(container);
    if(!c || !instance) return;
    ExtFreeParticles(c,instance->numParticles,instance->particleIndices);
    c->instances.erase(std::remove(c->instances.begin(),c->instances.end(),instance),c->instances.end());
    c->state.erase(instance);
    std::free(instance->particleIndices);
    delete instance;
    c->shapesDirty=true;
}
void __cdecl ExtDestroyObject(void*) {
    // Assets are only created by the editor-time mesh importers, which this
    // runtime does not provide; cooked assets belong to the engine.
}
void* __cdecl ExtCreateRigidFromMesh(const float*,int,const int*,int,float) { return nullptr; }
void* __cdecl ExtCreateClothFromMesh(const float*,int,const int*,int,float,float,float,float,float) { return nullptr; }
int __cdecl ExtCreateWeldedMeshIndices(const float* vertices,int count,int* uniqueVertices,int* originalToUnique,float threshold) {
    if(!vertices || count<=0 || !uniqueVertices || !originalToUnique) return 0;
    int unique=0; const float t2=threshold*threshold;
    for(int i=0;i<count;++i) {
        int found=-1;
        for(int u=0;u<unique && found<0;++u) {
            const float* a=vertices+3*i; const float* b=vertices+3*uniqueVertices[u];
            const float dx=a[0]-b[0],dy=a[1]-b[1],dz=a[2]-b[2];
            if(dx*dx+dy*dy+dz*dz<=t2) found=u;
        }
        if(found<0) { uniqueVertices[unique]=i; found=unique++; }
        originalToUnique[i]=found;
    }
    return unique;
}

void RebuildShapes(Container* c) {
    std::vector<int> offsets{0},indices,springs,triangles;
    std::vector<float> rest,stiffness,rotations,translations,springRest,springStiffness;
    int rigid=0;
    for(auto* instance:c->instances) {
        const ExtAsset* asset=instance->asset;
        auto& state=c->state[instance];
        // Carry the solved pose of rigids that already existed.
        if(instance->rigidIndex>=0 && instance->rigidIndex*9+8<static_cast<int>(c->rotations.size())) {
            state.rotation=QuaternionFromMatrix(&c->rotations[9*instance->rigidIndex]);
            std::memcpy(state.translation,&c->translations[3*instance->rigidIndex],sizeof(state.translation));
        }
        instance->rigidIndex=-1;
        if(asset->rigidStiffness>0) {
            instance->rigidIndex=rigid++;
            const float* m=instance->transform;
            float scale[3];
            for(int col=0;col<3;++col) scale[col]=std::sqrt(m[4*col]*m[4*col]+m[4*col+1]*m[4*col+1]+m[4*col+2]*m[4*col+2]);
            for(int k=0;k<instance->numParticles;++k) {
                indices.push_back(instance->particleIndices[k]);
                for(int a=0;a<3;++a) rest.push_back((asset->particles[4*k+a]-asset->rigidCenter[a])*(scale[a]>1e-6f?scale[a]:1.0f));
            }
            offsets.push_back(static_cast<int>(indices.size()));
            stiffness.push_back(std::min(asset->rigidStiffness,1.0f));
            rotations.insert(rotations.end(),state.rotation.begin(),state.rotation.end());
            translations.insert(translations.end(),state.translation,state.translation+3);
        }
        for(int s=0;s<asset->numSprings && asset->springIndices;++s) {
            const int a=asset->springIndices[2*s],b=asset->springIndices[2*s+1];
            if(a<0 || b<0 || a>=instance->numParticles || b>=instance->numParticles) continue;
            springs.push_back(instance->particleIndices[a]); springs.push_back(instance->particleIndices[b]);
            springRest.push_back(asset->springRestLengths?asset->springRestLengths[s]:0);
            springStiffness.push_back(asset->springCoefficients?asset->springCoefficients[s]:1);
        }
        instance->triangleIndex=asset->numTriangles>0?static_cast<int>(triangles.size()/3):-1;
        for(int t=0;t<asset->numTriangles*3 && asset->triangleIndices;++t) {
            const int v=asset->triangleIndices[t];
            triangles.push_back(v>=0 && v<instance->numParticles?instance->particleIndices[v]:-1);
        }
    }
    auto& solver=c->handle->solver;
    solver.SetRigids(offsets.data(),indices.data(),rest.data(),stiffness.data(),rotations.data(),translations.data(),rigid);
    solver.SetSprings(springs.data(),springRest.data(),springStiffness.data(),static_cast<int>(springRest.size()));
    solver.SetDynamicTriangles(triangles.data(),static_cast<int>(triangles.size()/3));
    c->rotations.assign(static_cast<std::size_t>(rigid)*9,0.0f);
    c->translations.assign(static_cast<std::size_t>(rigid)*3,0.0f);
    solver.GetRigidTransforms(c->rotations.data(),c->translations.data());
}

void __cdecl ExtPushToDevice(void* container) {
    auto* c=static_cast<Container*>(container);
    if(!c) return;
    WaitIdle(c->handle);
    auto& solver=c->handle->solver;
    if(c->activeDirty) {
        const int count=GetActiveList(c,c->activeScratch);
        solver.SetActive(c->activeScratch,count);
        c->handle->activeCount.store(solver.ActiveCount());
        c->activeDirty=false;
    }
    solver.SetParticles(c->particles,c->maxParticles);
    solver.SetVelocities(c->velocities,c->maxParticles);
    solver.SetPhases(c->phases,c->maxParticles);
    solver.SetNormals(c->normals,c->maxParticles);
    if(c->shapesDirty) { RebuildShapes(c); c->shapesDirty=false; }
}
void __cdecl ExtPullFromDevice(void* container) {
    auto* c=static_cast<Container*>(container);
    if(!c) return;
    ReadAfterUpdate(c->handle,[c] {
        auto& solver=c->handle->solver;
        solver.GetParticles(c->particles,c->maxParticles);
        solver.GetVelocities(c->velocities,c->maxParticles);
        solver.GetPhases(c->phases,c->maxParticles);
        solver.GetNormals(c->normals,c->maxParticles);
        if(!c->rotations.empty()) solver.GetRigidTransforms(c->rotations.data(),c->translations.data());
    });
}
void __cdecl ExtTickContainer(void* container,float dt,int substeps,void* timers) {
    auto* c=static_cast<Container*>(container);
    if(!c) return;
    ExtPushToDevice(c); FlexUpdateSolver(c->handle,dt,substeps,timers); ExtPullFromDevice(c); FlexWaitFence();
}

#define KF2VR_FLEX_EXPORT(dll,name,fn) {dll,name,reinterpret_cast<void*>(&fn)}
const Export exports[]{
    KF2VR_FLEX_EXPORT("flexRelease_x64.dll","flexInit",FlexInit),
    KF2VR_FLEX_EXPORT("flexRelease_x64.dll","flexShutdown",FlexShutdown),
    KF2VR_FLEX_EXPORT("flexRelease_x64.dll","flexAlloc",FlexAlloc),
    KF2VR_FLEX_EXPORT("flexRelease_x64.dll","flexFree",FlexFree),
    KF2VR_FLEX_EXPORT("flexRelease_x64.dll","flexCreateSolver",FlexCreateSolver),
    KF2VR_FLEX_EXPORT("flexRelease_x64.dll","flexDestroySolver",FlexDestroySolver),
    KF2VR_FLEX_EXPORT("flexRelease_x64.dll","flexUpdateSolver",FlexUpdateSolver),
    KF2VR_FLEX_EXPORT("flexRelease_x64.dll","flexSetParams",FlexSetParams),
    KF2VR_FLEX_EXPORT("flexRelease_x64.dll","flexSetActive",FlexSetActive),
    KF2VR_FLEX_EXPORT("flexRelease_x64.dll","flexGetActive",FlexGetActive),
    KF2VR_FLEX_EXPORT("flexRelease_x64.dll","flexGetActiveCount",FlexGetActiveCount),
    KF2VR_FLEX_EXPORT("flexRelease_x64.dll","flexSetParticles",FlexSetParticles),
    KF2VR_FLEX_EXPORT("flexRelease_x64.dll","flexGetParticles",FlexGetParticles),
    KF2VR_FLEX_EXPORT("flexRelease_x64.dll","flexSetVelocities",FlexSetVelocities),
    KF2VR_FLEX_EXPORT("flexRelease_x64.dll","flexGetVelocities",FlexGetVelocities),
    KF2VR_FLEX_EXPORT("flexRelease_x64.dll","flexSetPhases",FlexSetPhases),
    KF2VR_FLEX_EXPORT("flexRelease_x64.dll","flexGetPhases",FlexGetPhases),
    KF2VR_FLEX_EXPORT("flexRelease_x64.dll","flexSetNormals",FlexSetNormals),
    KF2VR_FLEX_EXPORT("flexRelease_x64.dll","flexGetNormals",FlexGetNormals),
    KF2VR_FLEX_EXPORT("flexRelease_x64.dll","flexGetDensities",FlexGetDensities),
    KF2VR_FLEX_EXPORT("flexRelease_x64.dll","flexGetBounds",FlexGetBounds),
    KF2VR_FLEX_EXPORT("flexRelease_x64.dll","flexSetConvexes",FlexSetConvexes),
    KF2VR_FLEX_EXPORT("flexRelease_x64.dll","flexSetTrianglesAdvanced",FlexSetTrianglesAdvanced),
    KF2VR_FLEX_EXPORT("flexRelease_x64.dll","flexSetForceFields",FlexSetForceFields),
    KF2VR_FLEX_EXPORT("flexRelease_x64.dll","flexSetFence",FlexSetFence),
    KF2VR_FLEX_EXPORT("flexRelease_x64.dll","flexWaitFence",FlexWaitFence),
    KF2VR_FLEX_EXPORT("flexRelease_x64.dll","flexStartRecord",FlexStartRecord),
    KF2VR_FLEX_EXPORT("flexRelease_x64.dll","flexStopRecord",FlexStopRecord),
    KF2VR_FLEX_EXPORT("flexExtRelease_x64.dll","flexExtCreateContainer",ExtCreateContainer),
    KF2VR_FLEX_EXPORT("flexExtRelease_x64.dll","flexExtDestroyContainer",ExtDestroyContainer),
    KF2VR_FLEX_EXPORT("flexExtRelease_x64.dll","flexExtAllocParticles",ExtAllocParticles),
    KF2VR_FLEX_EXPORT("flexExtRelease_x64.dll","flexExtFreeParticles",ExtFreeParticles),
    KF2VR_FLEX_EXPORT("flexExtRelease_x64.dll","flexExtGetActiveList",ExtGetActiveList),
    KF2VR_FLEX_EXPORT("flexExtRelease_x64.dll","flexExtGetParticleData",ExtGetParticleData),
    KF2VR_FLEX_EXPORT("flexExtRelease_x64.dll","flexExtGetRigidData",ExtGetRigidData),
    KF2VR_FLEX_EXPORT("flexExtRelease_x64.dll","flexExtGetTriangleData",ExtGetTriangleData),
    KF2VR_FLEX_EXPORT("flexExtRelease_x64.dll","flexExtAddObject",ExtAddObject),
    KF2VR_FLEX_EXPORT("flexExtRelease_x64.dll","flexExtRemoveObject",ExtRemoveObject),
    KF2VR_FLEX_EXPORT("flexExtRelease_x64.dll","flexExtDestroyObject",ExtDestroyObject),
    KF2VR_FLEX_EXPORT("flexExtRelease_x64.dll","flexExtCreateRigidFromMesh",ExtCreateRigidFromMesh),
    KF2VR_FLEX_EXPORT("flexExtRelease_x64.dll","flexExtCreateClothFromMesh",ExtCreateClothFromMesh),
    KF2VR_FLEX_EXPORT("flexExtRelease_x64.dll","flexExtCreateWeldedMeshIndices",ExtCreateWeldedMeshIndices),
    KF2VR_FLEX_EXPORT("flexExtRelease_x64.dll","flexExtPushToDevice",ExtPushToDevice),
    KF2VR_FLEX_EXPORT("flexExtRelease_x64.dll","flexExtPullFromDevice",ExtPullFromDevice),
    KF2VR_FLEX_EXPORT("flexExtRelease_x64.dll","flexExtTickContainer",ExtTickContainer),
};
#undef KF2VR_FLEX_EXPORT
} // namespace

const Export* Exports(int& count) { count=static_cast<int>(std::size(exports)); return exports; }

void SetLog(LogFunction log) { logFunction.store(log); }
void Log(const char* format,...) {
    const auto log=logFunction.load();
    if(!log) return;
    char text[512];
    va_list args; va_start(args,format); std::vsnprintf(text,sizeof(text),format,args); va_end(args);
    log("%s",text);
}

Statistics CurrentStatistics() {
    return {solverCount.load(),containerCount.load(),0,lastUpdateMs.load()};
}

} // namespace kf2vr::flex
