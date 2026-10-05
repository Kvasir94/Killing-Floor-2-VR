#pragma once

#include "GameScript.h"
#include "kf2vr/adapter/VerifiedLayout.h"

namespace kf2vr::adapter {

// Native KFWeapon::WeaponProcessViewRotation; the exec wrapper's register
// setup verifies this ABI in the pinned executable (see implementation).
using WeaponViewRotationFn=void(*)(void*,void*,float,pinned::NativeRotator*);
inline constexpr std::uintptr_t kWeaponViewRotationRva=0xe000c0;
bool SuppressManagedRecoil(GameScript& script, void* bridge, void* pawn,
                            void* weapon, void* controller);

// True means the exact item is registered, including when its pose is stale.
// Only a current primary pose returns a presenter that may originate gameplay.
bool ResolveItemPresenter(GameScript& script, void* bridge, void* pawn,
                           void* weapon, void*& presenter);
// Called only after the real stock shot body, including ammo-saving perks.
void CompleteMagazineShot(GameScript& script, void* bridge, void* pawn,
                          void* weapon, void* function);
// Synchronous pure availability policy; never writes stock ammunition.
bool RouteMagazineFeedEvent(GameScript& script, void* bridge, void* pawn,
                            void* object, void* function, const void* locals, void* result);
bool RouteManagedWeaponLifecycle(GameScript& script, void* bridge, void* pawn,
                                  void* object, void* function, const void* locals);
bool RouteManagedSprint(GameScript& script, void* bridge, void* pawn,
                          void* object, void* function, const void* locals);
// supportHand receives the hand currently bracing/supporting the same item, or -1.
int ManagedRecoilHand(GameScript& script, void* bridge, void* pawn, void* weapon, void* function,
                      int* supportHand=nullptr);
// Also routes local melee defense: a grab asked of MyKFWeapon is answered by
// the actual blocking item, and stock block/parry effects notify the bridge.
bool RouteManagedMelee(GameScript& script, void* bridge, void* pawn,
                         void* object, void* function, const void* locals, void* result);

// Pawn fire callbacks still own stock impacts, timestamps and Zed-time work.
// Their common attachment and replication receipts are selected only inside
// synchronous explicit-item callbacks. Nested calls retain each item's live
// state and restore the exact outer selection on every exit.
// Incoming stock pawn callbacks separately scope MyKFWeapon to one eligible
// blocker, leaving damage/perk processing and the normal selection untouched.
class WeaponEffectsScope {
public:
    explicit WeaponEffectsScope(GameScript& script) : script_(script) {}
    ~WeaponEffectsScope();
    WeaponEffectsScope(const WeaponEffectsScope&)=delete;
    WeaponEffectsScope& operator=(const WeaponEffectsScope&)=delete;
    void Enter(void* bridge, void* pawn, void* object, void* function, const void* locals);
private:
    struct PawnState {
        void* weapon{};
        void* attachment{};
        std::uint8_t firingMode{}, flashCount{};
        pinned::NativeVector3 flashLocation{}, lastFlashLocation{};
    };
    PawnState ReadPawnState();
    void WritePawnState(const PawnState& state);
    static thread_local WeaponEffectsScope* top_;
    WeaponEffectsScope* parent_{};
    WeaponEffectsScope* stockOwner_{};
    WeaponEffectsScope* suspendedBy_{};
    GameScript& script_;
    void* pawn_{};
    void* inventory_{};
    void* runtime_{};
    void* defensivePawn_{};
    void* savedDefensiveWeapon_{};
    PawnState saved_{};
    bool ownsState_{};
};

} // namespace kf2vr::adapter
