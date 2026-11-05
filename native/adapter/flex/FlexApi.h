#pragma once
// The portable backend's replacements for the FleX 1.0.5 exports KFGame
// imports, by export name. Solver updates run on a worker thread between
// flexSetFence/flexUpdateSolver and flexWaitFence, as the CUDA build did.
#include <cstdarg>

namespace kf2vr::flex {

struct Export { const char* dll; const char* name; void* function; };

// Every flexRelease/flexExtRelease export that KFGame (Steam or Epic) imports.
const Export* Exports(int& count);

using LogFunction=void(*)(const char* format,...);
void SetLog(LogFunction log);
void Log(const char* format,...);

// Counters for the adapter log; no effect on simulation.
struct Statistics { int solvers=0; int containers=0; int activeParticles=0; double lastUpdateMs=0; };
Statistics CurrentStatistics();

} // namespace kf2vr::flex
