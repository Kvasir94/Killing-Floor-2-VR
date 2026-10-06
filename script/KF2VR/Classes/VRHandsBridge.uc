// Local prototype adapter. Stock weapons retain their inventory, firing,
// reload, animation notifies and FX. The native adapter supplies world poses.
class VRHandsBridge extends Actor config(Game);

// Written only by the opt-in automated performance fixture; zero in play.
var transient int NativeBenchmarkPhase;

struct VRHandState
{
    var vector Position;
    var rotator AimRotation;
    var KFWeapon Item;
    var int SupportOwner;
    var bool bGrip;
    var bool bGripArmed;
    var bool bTrigger;
    var bool bTriggerArmed;
    var vector FirePosition;
    var rotator FireRotation;
};

// Shared hand rig and placement code; each compatible gun supplies its own
// authored grip pose and moving support part. Array order is the Y cycle.
struct VRWeaponProfile
{
    var name WeaponClassName;
    var name RootBone;
    var name IdleAnimation;
    var name SupportBone;
    var name MuzzleSocket;
    var name SecondaryMuzzleSocket;
    var name LaserSocket;
    // Authored bore frame relative to RootBone (+X for ordinary rigs).
    // MG3 models its barrel along root +Z; aim and recoil remain bore-relative.
    var rotator BoreRotation;
    // Set when the muzzle socket hangs off a part that moves against the
    // receiver. The socket still gives the beam its origin; its rotation is
    // discarded in favour of the aim the shot itself uses.
    var bool bLaserUsesBoreRotation;
    var bool bFirearm;
    var bool bOneHanded;
    // Sidearms brace at the authored grip without steering from wrist spacing.
    var bool bPistolBrace;
    // Some rigs place the support wrist beside/below the primary wrist rather
    // than along the bore. Aim those two-hand profiles along the bore while
    // retaining the authored wrist positions and rotations for attachment.
    var bool bTwoHandBoreAim;
    var bool bUseSharedPistolBrace;
    var bool bGripAltFire;
    // 0 none, 1 persistent trigger mode, 2 one-shot secondary, 3 held secondary.
    var byte AlternateKind;
    var string PrimaryModeLabel, AlternateModeLabel;
    var bool bPhysicalMelee;
    var bool bPhysicalDualGauntlets;
    // Some two-hand axe rigs author the right hand above the left on the
    // shaft. Physical placement uses the lower authored hand as its primary.
    var bool bPhysicalLowerHandlePrimary;
    var vector MeleeHeadStart, MeleeHeadEnd;
    var float MeleeRadius;
};

var array<VRWeaponProfile> WeaponProfiles;
var int ActiveProfile;

// A profile is authored against one exact first-person rig. A subclass inherits
// it only after that subclass has been confirmed to keep the same grip bones,
// muzzle sockets and idle animation, and every confirmed pair is listed here.
struct VRProfileAlias
{
    var name SubclassName;
    var name ProfileClassName;
};

var array<VRProfileAlias> AuditedSubclasses;

// Controller fit profiles. FirearmAimPitch/Yaw/RollDegrees are `var config`, so
// their class defaults are whatever the INI last saved - reading
// class'VRHandsBridge'.default.FirearmAimPitchDegrees returns the user's own
// current override, not a profile default, and "reset to default" that way is a
// no-op. These entries are deliberately NOT config, so they keep the compiled
// profile fit and can restore it.
// The Quest 2 numbers are the conversion documented in docs/CONTROLLER_PROFILES.md:
// SteamVR's Quest 2 raw-to-aim rotation is -39.4 degrees and the user's authored
// KF1 firearm grip is -48, so the residual KF2 correction is -8.6 degrees of
// local pitch. Neutral is the uncorrected OpenXR aim pose.
// This is an explicit user preset, not headset autodetection: the adapter does
// not currently report the live OpenXR interaction profile to script.
struct VRControllerFitProfile
{
    var name ProfileId;
    var string Label;
    var float FirearmPitchDegrees;
    var float FirearmYawDegrees;
    var float FirearmRollDegrees;
};

var array<VRControllerFitProfile> ControllerFitProfiles;
// Explicit user preset. Config, so an unset or unknown value falls back to the
// first compiled profile rather than to whatever the fit happens to be now.
var config name ActiveControllerFitProfile;

var KFPlayerController PC;
var KFPawn_Human Human;
// Set by VRPhysicalCrouch while a lowered headset owns the stock crouch. The
// player's real head already carries the drop, so the eye is held at standing
// height; CrouchEyeLift only decays after exit so the stand-up eases out.
var bool bPhysicalCrouchEye;
var float CrouchEyeLift;
var VRHandState Hands[2];
// Flat native ingress; hand ownership and interactions live in Hands[].
var vector LeftPosition, RightPosition, HeadPosition;
var float LeftGripValue, RightGripValue;
var float LeftTriggerValue, RightTriggerValue;
var rotator LeftRotation, RightRotation, BodyRotation;
// Full tracked orientation for presentation; never substituted for firearm aim.
var rotator NativeHeadRotation, NativeLeftGripRotation, NativeRightGripRotation;
var int NativeValidMask, NativeGripMask, NativeTriggerMask, NativeButtonMask;
var int NativeConnection;
var int NativePhysicalButtonMask, NativePhysicalButtonActiveMask, NativeIndependentHands;
var int NativeStickClickMask, NativeStickClickActiveMask, NativeHapticMask;
var float NativeHapticStrength, NativeHapticDuration;
// Independent requests for interactions with different feedback in each hand.
// Native consumes this lane alongside the legacy shared pulse, then clears it.
var int NativeHandHapticMask;
// Capability handshake is set only when the native pre-animation hook calls
// ReloadAudioHookGate. Older adapters leave stock notifications untouched.
var bool bReloadAudioHookReady, bReloadAudioOwned;
var float NativeLeftHapticStrength, NativeLeftHapticDuration;
var float NativeRightHapticStrength, NativeRightHapticDuration;
// Boxing-glove bell cues for the native adapter to play (VRBoxingGloves BELL_*);
// it clears the mask once played.
var int NativeBellRequest;
// Hands that just fired or struck (native recoil and physical melee); VRHitHaptics consumes it.
var int NativeStrikeMask;
var VRHitHaptics HitHaptics;
var int NativeControlsEnabled, NativeWeaponReady;
// Set while a stock GFx menu (trader, pause, popup) owns input. Native blanks
// the stock gamepad pad on it, independent of its render-side menu state.
var int NativeMenuInputBlocked;
// Refreshed at the native viewport boundary, including while game Tick is paused.
var int NativeMenuActive, NativeMenuContextValid;
var Object NativeMenuTarget;
// Native scopes these display/viewport changes around rendering only. The
// manager and its widgets retain focus, purchases, callbacks and movie state.
var int NativeMenuRenderStage;
var KFGFxMoviePlayer_Manager MenuRenderManager;
var KFGFxMoviePlayer_HUD MenuRenderMovieHUD;
var GameViewportClient MenuRenderViewport;
var HUD MenuRenderHUD;
var GFxObject MenuRenderRoot, MenuRenderHUDRoot;
var bool bMenuRenderRootVisible, bMenuRenderHUDVisible, bMenuRenderShowHUD;
var bool bMenuRenderManagerDisable, bMenuRenderManagerCapture;
var bool bMenuRenderHUDDisable, bMenuRenderHUDCapture;
var bool bMenuRenderViewportDisable, bMenuRenderViewportCaptured;
var int NativeHudMask, NativeHudDetail, HudWeaponMask;
// Lock-on weapon whose protected LockedTargets native copies into LockTarget0-5.
var KFWeapon LockSource;
var Pawn LockTarget0, LockTarget1, LockTarget2, LockTarget3, LockTarget4, LockTarget5;
var int NativeLockCount;
var float HudTrackingTime;
var vector HudStatusPosition, HudLeftAmmoPosition, HudRightAmmoPosition, HudSessionPosition, HudAlertPosition;
var rotator HudStatusRotation, HudLeftAmmoRotation, HudRightAmmoRotation, HudSessionRotation, HudAlertRotation;
var vector HudStatusSize, HudLeftAmmoSize, HudRightAmmoSize, HudSessionSize, HudAlertSize;
var VRSpatialHUD SpatialHUD;
var bool bSpatialHUDInitFailed;
var int NativeGripActiveMask, NativeTriggerActiveMask, NativeButtonActiveMask;
var int ArmedButtons;
var int LatchedXAction;
var int PreviousButtons;
var int WeaponHand;
// Explicit user preset, not automatic controller detection. See
// docs/CONTROLLER_PROFILES.md for the saved KF1/SteamVR Quest 2 conversion.
// The pinned compiler ignores config values in defaultproperties. The launcher
// seeds missing INI keys for this user's Quest 2 fit, preserving explicit edits.
var config bool bUseQuest2GripProfile;
// Set by the CAPTURE SEATED / STANDING tiles. Standing play in a STAGE space
// stands the view at the player's real eye height over the pawn's floor
// (HeadAim::SetFloorEye); seated play keeps the fixed pawn eye.
var config bool bSeatedPlay;
// Turn stick down to the rim toggles crouch (VRPhysicalCrouch.bButtonCrouch).
var config bool bStickCrouch;
var float NativeFloorEyeHeight; // metres above the pawn floor, 0 = fixed eye
var config float FirearmAimPitchDegrees;
var config float FirearmAimYawDegrees, FirearmAimRollDegrees;
// Where the wrist joint sits relative to the OpenXR grip origin (the palm
// centroid) on a Quest 2 controller, in the right hand's aim frame; the adapter
// mirrors it for the left hand. Every consumer of LeftPosition/RightPosition
// treats that point as the wrist, so without it the drawn hands and held guns
// sat a palm forward and inboard of the real ones. It is controller geometry,
// so it follows bUseQuest2GripProfile, not the aim-fit preset (RAW OPENXR AIM
// keeps it). Derivation: docs/CONTROLLER_PROFILES.md.
var vector Quest2WristOffset;
// The player's own nudge on that offset (calibration HAND FIT). Unseeded, so
// it starts at zero on top of the measured value.
var config vector HandWristAdjust;
// Read by the adapter before it publishes the hand positions (RefreshEyeBase).
var vector NativeWristOffset;
// Calibration ALIGN MARKERS: draws the tracked and drawn hand frames and the
// reload/grenade targets each frame, for touching the controllers together.
var bool bAlignmentMarkers;
var config float SpatialMenuDistance, SpatialMenuHeight, SpatialMenuScale;
// Persistent top HUD: soft comfort anchoring is the default; mode 1 keeps it
// screen-stable for accessibility. The launcher supplies safe initial values.
var config int TopHudFollowMode;
var config float TopHudDistance, TopHudHeight, TopHudScale;
var config float TopHudYawDeadZoneDegrees, TopHudPitchDeadZoneDegrees, TopHudTranslationDeadZone;
var config float TopHudDetailLookDegrees;
var config bool bWeaponAmmoReadouts;
var config bool bDamagePopups;
var config float WeaponAmmoReadoutScale, WeaponAmmoReadoutForward, WeaponAmmoReadoutHeight;
var config bool bWristwatchHUD;
var config vector WristwatchOffset;
var config rotator WristwatchRotation;
var config float WristwatchScale;
var float NativeHeadHeight, NativeStandingHeight;
var int NativeHeadTracked, NativeCalibrationEpoch, NativeHudSuppressMask;
var VRCalibrationPanel CalibrationPanel;
var config vector ChestGrenadeOffset;
// Session-only choice written into the launcher's isolated config.
var config bool bApplyVRRenderSettings;
var config bool bDisableRenderSettingsCache;
var config bool bVRPostProcessAA;
// Retain the stereo-unsafe screen/lens/noise effects for an A/B comparison.
var config bool bVRScreenEffects;
var VRRenderSettings RenderSettings;
var KFWeapon ActiveWeapon;
var KFWeapon LoggedContentPendingWeapon;
var float OriginalViewRecoil, OriginalSuppressionViewRecoil;
var float OriginalDoubleBarrelKickMomentum;
var bool bOriginalForceAttachmentsInTick;
var bool bOriginalAdditiveMoveAnim, bOriginalWeaponTilt;
var bool bWeaponMotionConfigured, bIdlePoseFrozen;
var KFSkeletalMeshComponent Arms;
var SkeletalMesh FloatingHandsMesh;
var MaterialInterface FloatingHandsMaterial;
var MaterialInstanceConstant BakedHandsMaterial;
var AnimTree ArmsTree;
var AnimNodeSequence IdlePose;
var VRFreeHandPose FreeHandPose;
var SkelControlSingleBone WristIK[2];
var bool bRiotShieldRaised;
var KFWeap_SMG_G18 RiotShieldWeapon;
// Gripping hands use the weapon's attachment graph. The independent wrist
// solvers below are only visible for free hands.
var KFSkeletalMeshComponent AttachedHands[2];
var name AttachedHandBones[2];
// Pistol-brace presentation (VRPistolBracePresentation): each attached hand's
// wrist, knuckle pivot and elbow in its attachment frame, its attachment to
// the gun bone, and the smoothed visual swing currently applied.
var vector BraceWristLocal[2], BracePivotLocal[2], BraceElbowLocal[2];
var vector BraceAttachPosition[2];
var quat BraceAttachRotation[2];
var byte BraceFrameReady[2], BraceApplied[2];
// Set once the unused hand of this attachment has been found visible again.
var byte OtherHandRevealLogged[2];
var float BraceAngle[2], BraceTime[2];
var float BraceFaceClearance, BraceMaxCorrection, BraceSmoothTime;
var vector GripInWeapon[2];
var quat GripRotationInWeapon[2];
var vector SupportGripOffsetInWeapon[2];
var quat SupportGripRotationInWeapon[2];
var vector IdleRootPosition;
var quat IdleRootRotation;
var bool bReadyPoseSettling;
var bool bSprintPoseSettling;
var quat LastTwoHandCorrectionQ;
var float TwoHandReleaseTime;
var float TwoHandEngageTime;
var quat TwoHandEngageFromQ;
var bool bWasTwoHandedAim;
var bool bTwoHandReleaseSmoothing;
// Hand-space recoil kick: one impulse per shot along the bore, applied over
// 45 ms and recovered over a weight-dependent 0.15-0.6 s (AS2 feel).
var float RecoilKick, RecoilKickFrom, RecoilKickPeak, RecoilKickStart, RecoilKickRecover;
var int LastKickShotCount;
// Authored roles are independent of physical hand indices. KF2's stock assets
// author right=primary, left=support; future left-hand profiles retarget these.
var vector PrimaryGrip, SupportGrip;
var vector SupportGripOffset;
var quat SupportGripRotation;
var bool bCalibrated, bNativeEnabled;
var KFSkeletalMeshComponent GripPoseMesh;
var array<AnimSet> SupportPoseAnimSets;
var bool bGripReferenceChecked;
var rotator FireRotation;
var vector FireLocation;
var vector LaserMuzzleLocation;
var rotator LaserMuzzleRotation;
var PointLightComponent HandFillLight;
var int NativePresentationCapture;
var int NativeKeepWorldDepth, NativeDepthSupported;
var array<MaterialInterface> OriginalWeaponMaterials;
var ESceneDepthPriorityGroup OriginalWeaponDepthGroup, OriginalWeaponOwnerDepthGroup;
var bool bOriginalWeaponOwnerDepth, bOriginalWeaponOccluder;
var float OriginalWeaponFOV;
var KFSkeletalMeshComponent OriginalFreeHandsOccluderMesh;
var bool bOriginalFreeHandsOccluder;
var VRCartridgeRendering CartridgeRendering;
var VRReloadMeshPresentation ReloadMeshPresentation;
// Acting-item perk context (VRPerkContext). Native brackets stock perk
// evaluation with NativePerkFire/Damage/Movement and NativePerkEnd.
var VRPerkContext PerkContext;
var KFWeapon SentGripItem[2];
var int SentGrip[2];
var float SentGripTime;
// Published for the native reload-mesh pop: the spare-load bone indices in
// composed order (element 0 is the magazine itself, the rest are the rounds
// riding it) and the 0.01 -> 1.18 -> 0.95 -> 1.00 scale over the first
// 0.24 s of a reload. Scale 0 means no pop is in flight.
var float NativeReloadMagScale;
var int NativeReloadMagBones[8];
var int NativeReloadMagBoneCount;
var VRAF2011Barrels AF2011Barrels;
var VRRiotShield RiotShield;
var VRPhysicalMelee PhysicalMelee;
var VRPhysicalBash PhysicalBash;
var bool bCarrySupportGrip;
var int PoseCount;
var bool bFreeHandPoseNeedsUpdate;
var float PlacedMuzzleDistance, PlacedRootError;
var int ReplayCapture;
var config bool bWeaponLasers;
var VRWeaponLaser WeaponLaser;
var bool bControlsLogged;
var int JumpBindIndex, UseBindIndex;
var VRFlamePresentation FlameRendering;
var VRM14Scope M14Scope;
var VRM14Laser M14Laser;
var vector NativeBackBlastLocation;
var rotator NativeBackBlastRotation;
var int NativeBackBlastReady;
// The per-item registry is opt-in during the engine-isolation proof. Production
// input/placement remains on the existing path until that gate is verified.
var VRHeldInventory HeldInventory;
var config bool bIndependentHands, bToggleGrip;
var config bool bHoldSupportGrip, bBodySlotsEnabled;
// Physical-stock option: the primary controller alone aims/anchors firearms.
// Support ownership, sighted handling and braced recoil remain grip-driven.
// False also preserves the existing alignment for profiles missing this key.
var config bool bDisableSupportHandAim;
// Hold-to-grab for empty hands: grip a real physics body on an ordinary zed
// or a corpse. Prototype gate; see docs/ZED_PHYSICS_GRAB_ROADMAP.md.
// Solo only; multiplayer follows the host's session setting.
var config bool bZedGrabEnabled;


// Struck Zeds stick on the fist for a few frames (VRHitStop).
var config bool bMeleeHitStop;
// Empty fists wear boxing gloves: a far stronger punch and a ringside bell on
// the trigger charge (VRBoxingGloves). PRACTICE AND TOOLS page.
var config bool bBoxingGloves;
// Optional hands-on reloads for supported guns (VRInteractiveReload), toggled
// on the VR CONTROLS page. Off keeps the stock button reload.
var config bool bInteractiveReloads;
// Local visual guidance only. Keep the player's choice while reloads are off;
// insertion assistance, ammunition, audio and haptics never depend on this.
var config bool bReloadHints;
// With interactive reloads: the pump shotgun needs its fore-end worked by hand
// after every shot (VRManualPump). Separate setting requiring reloads ON.
var config bool bManualPump;
// Off while the base reload feel is being tuned (user decision 2026-09-28):
// a faster-reloading perk widens the magazine magnet up to 1.6x
// (VRInteractiveReload.MagnetScale). Config key only, no menu entry.
var config bool bPerkReloadMagnet;
var config bool bUnlockDeferredReloads;
// Sight-line aim convergence at 20m for iron-sighted firearms (AS2 feel).
var config bool bSightLineConvergence;
// Legacy holster layout, relative to head minus 42 UU. Read only when
// BodyHolsterOffsets is unset; BodyHolsterOffset() converts it.
var config array<vector> BodySlotOffsets;
// Holster layout in the body frame (BodyPivot/BodyYaw), written by HOLSTER FIT.
var config array<vector> BodyHolsterOffsets;
// Shared body frame for holsters, the chest grenade and the dosh pocket; see
// BodyYaw. The neck pivot sits this far below the eyes along the head's up axis.
var rotator BodyFrameYaw;
var bool bBodyFrameValid;
var float BodyNeckLength;
var config array<name> SelectorFavorites;
var config bool bAutoSprint, bControllerRelativeMovement;
var config int MovementHand, PreferredWeaponHand;
// Comfort locomotion. 0 keeps the stock stick walk; 1 replaces it with
// teleport. Range and recharge are set against SprintSpeed rather than
// GroundSpeed: a teleport slower than the legs it replaces is a handicap, and
// the kite a raged Fleshpound demands stops being playable.
var config int LocomotionMode;
// Reach and recharge are shipped tuning, not preferences: no menu sets them,
// so a value found in a profile was always an older preset that outlived its
// release (the 650 UU sprint-parity hop survived every later retune and was
// what the 2026-09-26 playtest felt as "short and abrupt"). They are set in
// ValidateTeleportPreferences and never read from or saved to the ini.
var float TeleportRange, TeleportSustainedSpeed;
var float TeleportMinCooldown, TeleportMaxCooldown;
var config float TeleportAscentLimit, TeleportDescentLimit, TeleportNavRadius;
var config bool bTeleportArrivalFacing;
// Degrees added to the movement hand's grip pitch before the arc is thrown, for
// controllers whose grip pose sits low at a relaxed wrist.
var config float TeleportAimPitch;
var config float BlinkOutSeconds, BlinkInSeconds, BlinkScale;
var float NativeBlinkFX;
var int NativeTeleports, NativeTeleportRefused;
var bool bTeleportPreferencesValidated;
var int NativeStickActiveMask;
var float LeftStickX, LeftStickY, RightStickX, RightStickY;
var int NativeSelectorCapture;
var float NativeMoveX, NativeMoveY, NativeTurnX;
var VRHandInventory HandInventory;
var VRInventoryFocus InventoryFocus;
var int NativeFocusRequested;
var float NativeFocusScale;
var float NativeFocusFX;
// A presenter owns all legacy calibration/motion/laser fields for one item.
// Only the root bridge receives native input and owns the neutral wrist rig.
var VRHandsBridge RootBridge;
var VRWeaponRuntime PresentedItem;
// Ballistic scopes never invoke sight transitions, animation or FOV APIs.
var int NativeHandlingEnabled, NativeHandlingScopes, NativeHandlingRestores, NativeHandlingFault;
// Projectiles whose stock world-Z toss was taken back off after spawn.
var int NativeTossSuppressions;
var int CameraComfortCorrections;
var int CosmeticBloodLensRemovals;
var vector NativeEyeBase, RoomMoveRequested, RoomMoveAccepted;
// Metres the rendered head and hands may lean past the pawn's capsule; read
// by the native adapter every frame (HeadAim BoundRoomView). 5 cm normally.
// Widened toward ZedLeanMetres while a living Zed is pressed against the
// player, so a lunge reaches into it instead of stopping capsule to capsule,
// but never nearer a wall than LeanWallMargin. See UpdateLeanAllowance.
var float NativeLeanAllowance;
var float ZedLeanMetres, ZedContactGap, LeanWallMargin;
var int NativeRecenterRequested;

// Native calls this before eye-target resize, at the controller tick boundary.
// Applying renderer settings during viewport Draw can retain the old Canvas
// backbuffer reference and make the resize fail. No work in passive/replay mode.
// Never store an effective server refusal in the player's solo preference.
simulated function QueueHandHaptic(int Mask, float Strength, float Duration)
{
    if (!(Strength > 0 && Strength <= 1 && Duration > 0 && Duration <= 1)) return;
    Mask = Mask & 3;
    if ((Mask & 1) != 0)
    {
        if ((NativeHandHapticMask & 1) == 0)
        { NativeLeftHapticStrength = 0; NativeLeftHapticDuration = 0; }
        NativeLeftHapticStrength = FMax(NativeLeftHapticStrength, Strength);
        NativeLeftHapticDuration = FMax(NativeLeftHapticDuration, Duration);
    }
    if ((Mask & 2) != 0)
    {
        if ((NativeHandHapticMask & 2) == 0)
        { NativeRightHapticStrength = 0; NativeRightHapticDuration = 0; }
        NativeRightHapticStrength = FMax(NativeRightHapticStrength, Strength);
        NativeRightHapticDuration = FMax(NativeRightHapticDuration, Duration);
    }
    NativeHandHapticMask = NativeHandHapticMask | Mask;
}

simulated function int ReloadAudioHookGate()
{
    bReloadAudioHookReady = true;
    return (bReloadAudioOwned || bInteractiveReloads) ? 1 : 0;
}

simulated function BeforeReloadAnimation(KFWeapon W, name Sequence)
{
    if (HandInventory == None || HandInventory.Input == None || HandInventory.Input.Reloads == None) return;
    if (HandInventory.Input.Reloads.Audio != None) HandInventory.Input.Reloads.Audio.BeforeAnimation(W, Sequence);
    if (HandInventory.Input.Reloads.Pump != None) HandInventory.Input.Reloads.Pump.BeforeAnimation(W, Sequence);
    if (HandInventory.Input.Reloads.ManualAction != None) HandInventory.Input.Reloads.ManualAction.BeforeAnimation(W, Sequence);
}

simulated function bool ZedGrabAllowed()
{
    if (RootBridge != None) return RootBridge.ZedGrabAllowed();
    return WorldInfo.NetMode == NM_Standalone && bZedGrabEnabled;
}

simulated function bool MultiplayerGrabHostAllowed()
{
    return false;
}

simulated function bool RequestNetworkGrabDamage(Pawn Victim, float Amount, vector HitLocation, vector Momentum, name BoneName)
{
    if (RootBridge != None) return RootBridge.RequestNetworkGrabDamage(Victim, Amount, HitLocation, Momentum, BoneName);
    return false;
}

simulated function bool IsLocalVRContext()
{
    return (WorldInfo.NetMode == NM_Standalone || WorldInfo.NetMode == NM_ListenServer)
        && PC != None && LocalPlayer(PC.Player) != None;
}

simulated function EnforceRenderSettings()
{
    // SCALE SET saves the current system-settings INI. Only the launcher with
    // isolated INI paths opts in; ordinary/manual configs default to False.
    if (!bApplyVRRenderSettings || NativeConnection != 1 || !IsLocalVRContext()
        || PC == None || LocalPlayer(PC.Player) == None) return;
    if (RenderSettings == None)
    {
        RenderSettings = new(self) class'VRRenderSettings';
        `log("KF2VR_RENDER_AB revision=1 settingsCache=" $ (!bDisableRenderSettingsCache));
    }
    RenderSettings.bDisableReadbackCache = bDisableRenderSettingsCache;
    RenderSettings.Update(PC, bVRPostProcessAA, bVRScreenEffects);
}

simulated function VRSessionUI MenuSession()
{
    local VRGameViewportClient VRViewport;
    if (RootBridge != None) return RootBridge.MenuSession();
    if (PC == None || LocalPlayer(PC.Player) == None) return None;
    VRViewport = VRGameViewportClient(LocalPlayer(PC.Player).ViewportClient);
    return VRViewport != None ? VRViewport.VRSession : None;
}

simulated function RefreshMenuState()
{
    local VRGameViewportClient VRViewport;
    if (PC != None && LocalPlayer(PC.Player) != None)
        VRViewport = VRGameViewportClient(LocalPlayer(PC.Player).ViewportClient);
    if (VRViewport != None && VRViewport.VRSession != None)
    {
        VRViewport.VRSession.AttachHands(self);
        VRViewport.VRSession.RefreshMenuState();
        NativeMenuContextValid = VRViewport.VRSession.NativeMenuContextValid;
        NativeMenuActive = VRViewport.VRSession.NativeMenuActive;
        NativeMenuTarget = VRViewport.VRSession.NativeMenuTarget;
        return;
    }
    NativeMenuContextValid = int(PC != None && IsLocalVRContext()
        && LocalPlayer(PC.Player) != None);
    NativeMenuActive = int(NativeMenuContextValid != 0 && PC.MyGFxManager != None
        && (PC.MyGFxManager.bMenusActive || PC.MyGFxManager.bMenusOpen || PC.MyGFxManager.CurrentPopup != None));
    NativeMenuTarget = None;
    if (NativeMenuActive != 0)
    {
        if (PC.MyGFxManager.CurrentPopup != None) NativeMenuTarget = PC.MyGFxManager.CurrentPopup;
        else NativeMenuTarget = PC.MyGFxManager.CurrentMenu;
    }
}

simulated function PrepareMenuInput()
{
    RefreshMenuState();
    if (NativeMenuActive == 0) return;
    if (PC.MyGFxManager.bUsingGamepad) PC.MyGFxManager.OnInputTypeChanged(false);
    // Native GFx input reads the adapter's scoped virtual viewport cursor.
    // SetMouse warps the OS cursor and cannot address our larger eye surface.
}

// Capsules keep a lunging player's head a full two radii from a Zed's centre
// -- about arm's length from its chest, and out of reach of one that rears
// back -- so fists and bashes could not land even with a real lunge. While a
// living Zed is against the capsule the view and hands may lean further, up
// to ZedLeanMetres. Walls come first: the widened lean is capped by the
// nearest world geometry in any direction around the eye, swept with a
// head-sized box, less LeanWallMargin, and it snaps back at once when a wall
// is the limit. Only the lean back after a Zed leaves is eased. None of this
// moves the pawn; it is presentation only.
simulated function UpdateLeanAllowance(float DeltaTime)
{
    local KFPawn_Monster M;
    local float Target, Gap, Limit;
    local vector Eye, HitLocation, HitNormal;
    local rotator Direction;
    local int I;
    Target = 0.05;
    if (Human != None && Human.Health > 0 && Human.Physics == PHYS_Walking && ZedLeanMetres > 0.05)
    {
        foreach WorldInfo.AllPawns(class'KFPawn_Monster', M, Human.Location, 250)
        {
            if (M.bDeleteMe || M.Health <= 0 || M.bPlayedDeath || M.GetTeamNum() == Human.GetTeamNum()) continue;
            Gap = VSize2D(M.Location - Human.Location) - Human.GetCollisionRadius() - M.GetCollisionRadius();
            if (Gap > ZedContactGap) continue;
            if (Abs(M.Location.Z - Human.Location.Z) > Human.GetCollisionHeight() + M.GetCollisionHeight()) continue;
            Target = ZedLeanMetres;
            break;
        }
    }
    // Widen at once; ease back only when the Zed goes, so the view is not
    // yanked out of a lunge.
    if (Target < NativeLeanAllowance) Target = FMax(Target, NativeLeanAllowance - DeltaTime * 0.8);
    // Walls always win, immediately, whenever the lean is above the default.
    if (Target > 0.05 && Human != None)
    {
        Eye = Human.Location + vect(0,0,1) * Human.BaseEyeHeight;
        Limit = Target * 100;
        for (I = 0; I < 16; ++I)
        {
            Direction.Yaw = I * 4096;
            if (Trace(HitLocation, HitNormal, Eye + vector(Direction) * (Target * 100 + LeanWallMargin),
                Eye, false, vect(10,10,10)) != None)
                Limit = FMin(Limit, VSize(HitLocation - Eye) - LeanWallMargin);
        }
        Target = FMax(0.05, FMin(Target, Limit / 100));
    }
    NativeLeanAllowance = Target;
}

simulated function RefreshEyeBase()
{
    NativeWristOffset = CurrentWristOffset();
    NativeFloorEyeHeight = (bSeatedPlay || Human == None) ? 0.0
        : (Human.default.CylinderComponent.CollisionHeight + Human.default.BaseEyeHeight) / 100.0;
    if (PC == None || PC.Pawn == None) return;
    NativeEyeBase = PC.Pawn == Human ? VREyeLocation() : PC.Pawn.GetPawnViewLocation();
}

// Right-hand aim frame, UU. Off with the Quest 2 profile: the raw grip origin.
simulated function vector CurrentWristOffset()
{
    local vector Offset;
    if (!bUseQuest2GripProfile) return vect(0,0,0);
    Offset = Quest2WristOffset + HandWristAdjust;
    // The adapter refuses anything past 20 UU; keep the nudge well inside it.
    if (VSize(Offset) > 16) Offset = Normal(Offset) * 16;
    return Offset;
}

// One frame of markers. Yellow: the OpenXR grip origin (palm centroid).
// Cyan: the wrist the game uses, with its aim axes (red forward, green up).
// Magenta: the drawn wrist bone. Touch the controllers together: the drawn
// hands should meet where the real ones do.
simulated function DrawAlignmentMarkers()
{
    local int H;
    local vector Wrist, Drawn, Palm, Forward, Up;
    local quat Q;
    local VRInteractiveReload Reloads;
    local VRChestGrenade Grenade;
    for (H = 0; H < 2; ++H)
    {
        if ((NativeValidMask & (1 << H)) == 0) continue;
        Wrist = H == 0 ? LeftPosition : RightPosition;
        Palm = PalmPosition(H);
        Drawn = RenderedHandPosition(H);
        Q = QuatFromRotator(H == 0 ? LeftRotation : RightRotation);
        Forward = QuatRotateVector(Q, vect(1,0,0));
        Up = QuatRotateVector(Q, vect(0,0,1));
        DrawDebugBox(Palm, vect(0.6,0.6,0.6), 255, 230, 0, false);
        DrawDebugBox(Wrist, vect(0.6,0.6,0.6), 0, 230, 255, false);
        DrawDebugLine(Palm, Wrist, 255, 255, 255, false);
        DrawDebugLine(Wrist, Wrist + Forward * 10, 255, 40, 40, false);
        DrawDebugLine(Wrist, Wrist + Up * 6, 40, 255, 40, false);
        DrawDebugBox(Drawn, vect(0.4,0.4,0.4), 255, 0, 255, false);
    }
    if (HandInventory == None || HandInventory.Input == None) return;
    Reloads = HandInventory.Input.Reloads;
    if (Reloads != None && Reloads.bActive && Reloads.Gun != None && Reloads.Gun.MySkelMesh != None)
    {
        // Green: where the ammunition must arrive; white: where it seats;
        // magenta: the ammunition the hand carries.
        DrawDebugBox(Reloads.AmmoTarget(), vect(0.8,0.8,0.8), 40, 255, 40, false);
        DrawDebugBox(Reloads.SeatLocation(), vect(0.5,0.5,0.5), 255, 255, 255, false);
        if (Reloads.HandMode == 1) DrawDebugBox(Reloads.HeldLocation(), vect(0.8,0.8,0.8), 255, 0, 255, false);
    }
    Grenade = HandInventory.Input.Grenade;
    if (Grenade != None)
    {
        // Orange: the grenade slot and its grab sphere around the palm.
        DrawDebugBox(Grenade.ChestGrabPosition(), vect(1,1,1), 255, 140, 0, false);
        DrawDebugSphere(Grenade.ChestGrabPosition(), Grenade.ChestGrabRadius(), 10, 255, 140, 0, false);
    }
}

// The palm centroid OpenXR reports as the grip origin: the published wrist
// minus the offset the adapter added. Reach zones (pouches, holsters, the
// grenade, the wallet) measure from here, because it is where the player's
// palm really is and it is the point they were all tuned against before the
// published hand position became the wrist.
simulated function vector PalmPosition(int Hand)
{
    local vector Offset;
    if (RootBridge != None) return RootBridge.PalmPosition(Hand);
    Offset = NativeWristOffset;
    if (Hand == 0)
    {
        Offset.Y = -Offset.Y;
        return LeftPosition - QuatRotateVector(QuatFromRotator(LeftRotation), Offset);
    }
    return RightPosition - QuatRotateVector(QuatFromRotator(RightRotation), Offset);
}

// Stock crouch still runs so every bIsCrouched bonus (spread, recoil, perk
// skills) and its replication stay stock; only the view's eye drop is undone.
// Lift is the gap to where a standing eye would be: zero at StartCrouch (which
// keeps world eye continuous), growing as EyeHeight eases to its crouched base.
simulated function vector VREyeLocation()
{
    local float Lift, MaxLift;
    if (Human == None) return vect(0,0,0);
    if (!bPhysicalCrouchEye && CrouchEyeLift <= 0) return Human.GetPawnViewLocation();
    MaxLift = Human.default.CylinderComponent.CollisionHeight - Human.CrouchHeight
        + Human.default.BaseEyeHeight - FMin(0.8 * Human.CrouchHeight, Human.CrouchHeight - 10);
    Lift = Human.default.CylinderComponent.CollisionHeight - Human.CylinderComponent.CollisionHeight
        + Human.default.BaseEyeHeight - Human.EyeHeight;
    // After exit, only decay: never pick up stair or landing dips as lift.
    Lift = FClamp(Lift, 0, (bPhysicalCrouchEye && Human.bIsCrouched) ? MaxLift : CrouchEyeLift);
    CrouchEyeLift = Lift > 0.1 ? Lift : 0.0;
    return Human.GetPawnViewLocation() + vect(0,0,1) * CrouchEyeLift;
}

// Body facing for every torso anchor, recomputed from the current head pose
// with no deadzone or catch-up, so a holster is always where it was the last
// time the player reached for it (docs/re/ARIZONA_SUNSHINE_2_RIG.md). The look
// direction decides it, which head roll cannot move. Past about 72 degrees of
// pitch that direction has almost no horizontal part, so the head's up axis,
// which points the way the body faces when looking down (and away from it
// when looking up), takes over until it alone decides at the vertical.
simulated function rotator BodyYaw()
{
    local vector X, Y, Z, Forward, Up;
    local float Horizontal;
    if (NativeHeadTracked != 0)
    {
        GetAxes(NativeHeadRotation, X, Y, Z);
        Forward = X; Forward.Z = 0;
        Up = Z; Up.Z = 0;
        if (X.Z > 0) Up = -Up;
        Horizontal = VSize(Forward);
        Forward += Up * FMax(0, 1 - Horizontal / 0.3);
        if (VSize(Forward) > 0.05)
        {
            BodyFrameYaw.Yaw = rotator(Forward).Yaw;
            bBodyFrameValid = true;
        }
    }
    if (!bBodyFrameValid) BodyFrameYaw.Yaw = PC != None ? PC.Rotation.Yaw : BodyRotation.Yaw;
    BodyFrameYaw.Pitch = 0; BodyFrameYaw.Roll = 0;
    return BodyFrameYaw;
}

// The neck, not the eyes: tipping the head to look down swings the eyes
// forward and down while the neck stays put, so anchors hung from here do not
// slide toward wherever the player looks.
// The belt ammo pouch on one hip, from the reload's belt offset in the torso
// frame. Physical reloads reach for it; the HUD pins the reserve count to it.
simulated function vector AmmoPouchPosition(int Hand, vector Offset)
{
    if (Hand == 1) Offset.Y = -Offset.Y;
    return BodyPivot() - vect(0,0,1) * (38 - BodyNeckLength) + (Offset >> BodyYaw());
}

simulated function vector BodyPivot()
{
    local vector X, Y, Z;
    if (NativeHeadTracked == 0) return HeadPosition - vect(0,0,1) * BodyNeckLength;
    GetAxes(NativeHeadRotation, X, Y, Z);
    return HeadPosition - Z * BodyNeckLength;
}

// Holster I in the body frame. A legacy BodySlotOffsets entry was relative to
// head minus 42 UU; the level-head pivot is head minus BodyNeckLength.
simulated function vector BodyHolsterOffset(int I, vector Fallback)
{
    if (BodyHolsterOffsets.Length == 5) return BodyHolsterOffsets[I];
    if (BodySlotOffsets.Length == 5) return BodySlotOffsets[I] - vect(0,0,1) * (42 - BodyNeckLength);
    return Fallback;
}

// The native tracking consumer supplies a bounded request before stock
// PlayerTick and consumes only this swept result. Keep this transaction
// separate from presentation for future saved-move prediction/server replay.
simulated function ApplyRoomMovement()
{
    local vector Before, Requested;
    RoomMoveAccepted = vect(0,0,0);
    if (!IsLocalVRContext() || PC == None || !PC.IsLocalController()
        || Human == None || PC.Pawn != Human || Human.Health <= 0
        || !PC.UsingFirstPersonCamera() || Human.Physics != PHYS_Walking
        || Human.IsDoingSpecialMove()) return;
    Requested = RoomMoveRequested;
    Requested.Z = 0;
    if (VSizeSq(Requested) > 225.01) return;
    if (DeferRoomMovement(Requested)) return;
    Before = Human.Location;
    Human.MoveSmooth(Requested);
    RoomMoveAccepted = Human.Location - Before;
}

// Standalone owns its own position and moves here and now. A network client
// must instead let the move pipeline apply this, at the same point the server
// will replay it, or the two sweep from different states and disagree on every
// move. Returning true means "taken; do not move the pawn here".
simulated function bool DeferRoomMovement(vector Requested)
{
    return false;
}

// The pinned compiler does not reliably emit config defaults from
// defaultproperties, and an old profile can carry zeroes from before these
// keys existed, so every value is recovered here the way VRSessionUI recovers
// its own. Range and recharge are deliberately NOT tied to SprintSpeed (460).
// Sprint parity -- the old 650 over 500 UU/s -- measured correctly and played
// badly: the arc costs real time to aim, so matching a runner's rate makes the
// hop feel like a penalty for using it. The current 1800 UU reach takes a
// deliberate 2.25 s on level ground, so it crosses a large room in one choice
// without becoming a rapid retreat chain. Tune this against how the room
// actually plays under pressure, not against what a sprinting player covers.
simulated function ValidateTeleportPreferences()
{
    if (bTeleportPreferencesValidated) return;
    bTeleportPreferencesValidated = true;
    if (LocomotionMode < 0 || LocomotionMode > 1) LocomotionMode = 0;
    // Shipped reach and recharge (see their declaration). The sustained speed
    // is also the authority rate (KF2VRNetPlayerController
    // TELEPORT_SERVER_SPEED), and the reach stays inside TELEPORT_LIMIT.
    TeleportRange = 1800;
    TeleportSustainedSpeed = 800;
    TeleportMinCooldown = 1;
    TeleportMaxCooldown = 2.50;
    // Validate vertical limits before deriving the longest possible hop.
    if (TeleportAscentLimit < 70 || TeleportAscentLimit > 1200) TeleportAscentLimit = 400;
    // MaxFallSpeed 1325 against gravity 1150 makes 763 the largest drop that
    // costs nothing on foot. Teleporting down is not worse than jumping down.
    if (TeleportDescentLimit < 100 || TeleportDescentLimit > 2000) TeleportDescentLimit = 700;
    // Full range over the sustained speed. Anything shorter quietly raises the
    // effective rate above the one number this is all tuned around. Use the
    // furthest legal 3-D spot because both client and authority bill VSize.
    if (TeleportMaxCooldown < FClamp(Sqrt(TeleportRange * TeleportRange
        + Square(FMax(TeleportAscentLimit, TeleportDescentLimit)))
        / FMax(TeleportSustainedSpeed, 1), TeleportMinCooldown, 4)
        || TeleportMaxCooldown > 4)
        TeleportMaxCooldown = FClamp(Sqrt(TeleportRange * TeleportRange
            + Square(FMax(TeleportAscentLimit, TeleportDescentLimit)))
            / FMax(TeleportSustainedSpeed, 1), TeleportMinCooldown, 4);
    if (TeleportNavRadius < 50 || TeleportNavRadius > 1000) TeleportNavRadius = 250;
    if (TeleportAimPitch != TeleportAimPitch || TeleportAimPitch < -30 || TeleportAimPitch > 45) TeleportAimPitch = 0;
    if (BlinkOutSeconds < 0 || BlinkOutSeconds > 0.5) BlinkOutSeconds = 0.08;
    if (BlinkInSeconds < 0 || BlinkInSeconds > 0.5) BlinkInSeconds = 0.12;
    if (BlinkScale < 0 || BlinkScale > 1) BlinkScale = 1.0;
}

// One relocation, one contract. Standalone moves the body here; a network
// client hands the request to its controller so the server decides, and the
// fade covers the round trip instead of a correction rubber-banding it.
simulated function bool RequestTeleport(vector Spot)
{
    if (DeferTeleport(Spot)) return true;
    ApplyTeleport(Spot);
    return false;
}

simulated function bool DeferTeleport(vector Spot)
{
    return false;
}

// Solo never defers, so nothing answers there; the network bridge's owner
// controller calls this when the server accepts or refuses.
simulated function TeleportAnswered(bool bAccepted)
{
    if (HandInventory == None || HandInventory.Input == None
        || HandInventory.Input.Teleport == None) return;
    HandInventory.Input.Teleport.ServerAnswered(bAccepted);
}

// The relocation contract the portal traversal already proved: clear the exit,
// move, read the position back, and put the body where it was if it did not
// land. SetLocation returning true is not proof the actor is where it was
// asked to be, because stock overlap callbacks run inside it and can move it
// again. Collision is never disabled and no coordinate is written directly.
simulated function bool ApplyTeleport(vector Spot)
{
    local vector Before;
    if (Human == None || PC == None || PC.Pawn != Human || Human.Health <= 0
        || Human.Physics != PHYS_Walking || Human.IsDoingSpecialMove())
    {
        ++NativeTeleportRefused;
        return false;
    }
    Before = Human.Location;
    if (!Human.SetLocation(Spot) || VSizeSq(Human.Location - Spot) > 1.0)
    {
        if (VSizeSq(Human.Location - Before) > 0.01) Human.SetLocation(Before);
        ++NativeTeleportRefused;
        return false;
    }
    Human.Velocity = vect(0,0,0);
    Human.Acceleration = vect(0,0,0);
    // What the shipped AI teleport settles with. It re-establishes walking and
    // the correct base from the new spot rather than asserting a physics mode.
    Human.SetMovementPhysics();
    // A queued physical step was measured against the body that just moved.
    // The native seam rewrites this every tick in standalone, but clearing it
    // here keeps the rule in one place for both paths.
    RoomMoveRequested = vect(0,0,0);
    RoomMoveAccepted = vect(0,0,0);
    ++NativeTeleports;
    return true;
}

// Invoked only by the pinned native world-tick seam and its completion hook.
function PrepareInventoryFocus()
{
    NativeFocusScale = 1.0;
    if (InventoryFocus != None) InventoryFocus.PrepareNativeFrame();
}

function FinishInventoryFocus()
{
    if (InventoryFocus != None) InventoryFocus.FinishNativeFrame();
    NativeFocusScale = 1.0;
}

simulated event Tick(float DeltaTime)
{
    if (!IsLocalVRContext() || PC == None || PC.Pawn == None)
    {
        ReleaseControls();
        if (InventoryFocus != None) InventoryFocus.Shutdown();
        if (HandInventory != None) { HandInventory.Shutdown(); HandInventory = None; }
        HandFillLight.SetEnabled(false);
        HideWeaponLaser();
        return;
    }
    if (PC.Pawn != Human)
    {
        ReleaseControls();
        if (InventoryFocus != None) InventoryFocus.Shutdown();
        if (HandInventory != None) { HandInventory.Shutdown(); HandInventory = None; }
        ArmsTree = None;
    }
    Human = KFPawn_Human(PC.Pawn);
    UpdateLeanAllowance(DeltaTime);
    if (Human == None || Human.Health <= 0)
    {
        ReleaseControls();
        if (InventoryFocus != None) InventoryFocus.Shutdown();
        if (HandInventory != None) { HandInventory.Shutdown(); HandInventory = None; }
        HandFillLight.SetEnabled(false); HideWeaponLaser(); return;
    }
    // Intercepted before its script body, also used to register this instance.
    NativeHandsUpdate();
    // Native session panels do not set the stock GFx menu flags. Refresh their
    // state before either hand can read a trigger or reload button this tick.
    RefreshMenuState();
    if ((NativeMenuActive != 0) != (NativeMenuInputBlocked != 0)) ReleaseControls();
    NativeMenuInputBlocked = int(NativeMenuActive != 0);
    UpdateSeekerLockOn();
    UpdateRiotShield();
    if (RootBridge == None) UpdatePerkGrips();
    if (RootBridge == None)
    {
        if (HitHaptics == None) HitHaptics = new(self) class'VRHitHaptics';
        HitHaptics.Update(self);
    }
    HandFillLight.SetEnabled(NativeValidMask != 0);
    if (!bNativeEnabled)
    {
        ReleaseControls(); if (InventoryFocus != None) InventoryFocus.Shutdown(); HideWeaponLaser();
        // The charge glow is only refreshed by the inventory update skipped here.
        if (HandInventory != None && HandInventory.FistCharge != None) HandInventory.FistCharge.CancelAll("disabled");
        return;
    }
    ApplyLocalBindings();
    if (InventoryFocus == None)
    {
        InventoryFocus = new(self) class'VRInventoryFocus';
        InventoryFocus.Initialize(self);
    }
    if (InventoryFocus != None)
    {
        InventoryFocus.Update(DeltaTime);
    }
    if (FreeHandPose == None) FreeHandPose = new(self) class'VRFreeHandPose';
    FreeHandPose.Advance(self, DeltaTime);
    InitializeFreeHands();
    if (bIndependentHands)
    {
        if (HandInventory != None && HandInventory.bShuttingDown) HandInventory = None;
        if (HandInventory == None)
        {
            ConfigureWeapon(None);
            HandInventory = new(self) class'VRHandInventory';
            if (!HandInventory.Initialize(self)) HandInventory = None;
        }
        if (HandInventory != None)
        {
            HandInventory.Update(DeltaTime);
            if (bAlignmentMarkers) DrawAlignmentMarkers();
        }
    }
    else
    {
        UpdateHands();
        if (PhysicalMelee != None) PhysicalMelee.Update();
        if (PhysicalBash != None) PhysicalBash.Update();
    }
    // Resource/movie creation stays on Tick; the native late-placement hook
    // may only update a previously created HUD.
    if (SpatialHUD == None && !bSpatialHUDInitFailed && NativeConnection > 0 && (NativeValidMask & 3) != 0)
    {
        SpatialHUD = Spawn(class'VRSpatialHUD', self);
        if (SpatialHUD == None || !SpatialHUD.InitializeHUD(self))
        {
            bSpatialHUDInitFailed = true;
            if (SpatialHUD != None) SpatialHUD.Destroy();
            SpatialHUD = None;
            `log("KF2VR_HUD unavailable: stock HUD preserved");
        }
    }
    UpdateSpatialHUD();
}

simulated function NativeHandsUpdate()
{
    bNativeEnabled = NativeConnection > 0;
}

simulated function ApplyLocalBindings()
{
    local PlayerInput PlayerControls;
    local KeyBind Binding;
    local int I;
    local bool FoundJump, FoundUse;
    PlayerControls = PC.PlayerInput;
    if (PlayerControls == None) return;
    // The XR gamepad applies one rescaled look deadzone. KF2's profile value
    // is a hard cut on top of it, so turning jumped from stopped to moving.
    // The profile reapplies it after login; keep it cleared in memory only.
    if (KFPlayerInput(PlayerControls) != None) KFPlayerInput(PlayerControls).GamepadDeadzoneScale = 0;
    if (JumpBindIndex >= 0 && JumpBindIndex < PlayerControls.Bindings.Length
        && UseBindIndex >= 0 && UseBindIndex < PlayerControls.Bindings.Length
        && PlayerControls.Bindings[JumpBindIndex].Name == 'XboxTypeS_A' && PlayerControls.Bindings[JumpBindIndex].Command == "GBA_Jump"
        && PlayerControls.Bindings[UseBindIndex].Name == 'XboxTypeS_B' && PlayerControls.Bindings[UseBindIndex].Command == "GBA_Use") return;
    // A saved flat-screen controller layout can remap these pad events after
    // login. Keep the VR actions explicit in memory; SetBind would SaveConfig.
    for (I = 0; I < PlayerControls.Bindings.Length; ++I)
    {
        if (PlayerControls.Bindings[I].Name == 'XboxTypeS_A')
        {
            PlayerControls.Bindings[I].Command = "GBA_Jump";
            JumpBindIndex = I;
            FoundJump = true;
        }
        if (PlayerControls.Bindings[I].Name == 'XboxTypeS_B')
        {
            PlayerControls.Bindings[I].Command = "GBA_Use";
            UseBindIndex = I;
            FoundUse = true;
        }
    }
    if (!FoundJump)
    {
        Binding.Name = 'XboxTypeS_A'; Binding.Command = "GBA_Jump";
        PlayerControls.Bindings.AddItem(Binding);
        JumpBindIndex = PlayerControls.Bindings.Length - 1;
    }
    if (!FoundUse)
    {
        Binding.Name = 'XboxTypeS_B'; Binding.Command = "GBA_Use";
        PlayerControls.Bindings.AddItem(Binding);
        UseBindIndex = PlayerControls.Bindings.Length - 1;
    }
    if (!bControlsLogged)
    {
        bControlsLogged = true;
        `log("KF2VR_CONTROLS reload=A/X switch=Y jump=B interact=LeftTrigger selfHeal=RightTriggerAtTorso saved=false");
    }
}

simulated function int FilterWeaponButtons(int Pressed, int Active)
{
    // X/flashlight is one physical button. Latch its initial action until an
    // actual release, so changing the grip modifier cannot trigger another.
    ArmedButtons = (ArmedButtons | (~Pressed & 10)) & Active;
    if ((Active & 1) == 0)
    {
        ArmedButtons = ArmedButtons & ~5;
        LatchedXAction = 0;
    }
    else if ((Pressed & 5) == 0)
    {
        ArmedButtons = ArmedButtons | (Active & 5);
        LatchedXAction = 0;
    }
    else if ((ArmedButtons & 1) != 0 && LatchedXAction == 0)
        LatchedXAction = Pressed & Active & 5;
    return ((Pressed & 10) | LatchedXAction) & ArmedButtons;
}

simulated function name HandBone(int Index)
{
    return Index == 0 ? 'LeftHand_1stP' : 'RightHand_1stP';
}

simulated function int FindProfileByClassName(name ClassName)
{
    local int I;
    if (ClassName == '') return -1;
    for (I = 0; I < WeaponProfiles.Length; ++I)
        if (WeaponProfiles[I].WeaponClassName == ClassName) return I;
    return -1;
}

// The trader asks before any weapon exists, so by class name. Stock duals are
// judged by VRWeaponPair, which knows which of them convert on pickup.
static function bool HasAuthoredProfile(name ClassName)
{
    local int I;
    if (ClassName == '') return false;
    // Optional Deadbolt inherits this exact stock mesh/rig; no package load here.
    if (ClassName == 'BreacherDeadbolt') return HasAuthoredProfile('KFWeap_HRG_Nailgun');
    for (I = 0; I < default.WeaponProfiles.Length; ++I)
        if (default.WeaponProfiles[I].WeaponClassName == ClassName) return true;
    return false;
}

simulated function int FindControllerFitProfile(name ProfileId)
{
    local int I;
    if (ProfileId == '') return -1;
    for (I = 0; I < ControllerFitProfiles.Length; ++I)
        if (ControllerFitProfiles[I].ProfileId == ProfileId) return I;
    return -1;
}

// Index of the profile whose compiled fit "reset to default" must restore.
// Falls back to entry 0 so an unset or stale INI name still resets to a real
// profile default instead of silently doing nothing.
simulated function int ActiveControllerFitProfileIndex()
{
    local int Index;
    Index = FindControllerFitProfile(ActiveControllerFitProfile);
    if (Index >= 0) return Index;
    return ControllerFitProfiles.Length > 0 ? 0 : -1;
}

simulated function string ActiveControllerFitProfileLabel()
{
    local int Index;
    Index = ActiveControllerFitProfileIndex();
    return Index >= 0 ? ControllerFitProfiles[Index].Label : "NO PROFILE";
}

// Reads the active profile's authored fit. Returns false and leaves the out
// parameters alone when no profile is available, so a caller can keep the
// current fit rather than zeroing it.
simulated function bool GetActiveProfileDefaultFit(out float OutPitch, out float OutYaw, out float OutRoll)
{
    local int Index;
    Index = ActiveControllerFitProfileIndex();
    if (Index < 0) return false;
    OutPitch = ControllerFitProfiles[Index].FirearmPitchDegrees;
    OutYaw = ControllerFitProfiles[Index].FirearmYawDegrees;
    OutRoll = ControllerFitProfiles[Index].FirearmRollDegrees;
    return true;
}

// The calibration reset entry point. Restores pitch/yaw/roll from the active
// profile and deliberately leaves bUseQuest2GripProfile alone: the toggle is a
// user preference, not part of the fit.
simulated function bool ApplyActiveProfileDefaultFit()
{
    local float P, Y, R;
    if (!GetActiveProfileDefaultFit(P, Y, R)) return false;
    FirearmAimPitchDegrees = FClamp(P, -80, 80);
    FirearmAimYawDegrees = FClamp(Y, -80, 80);
    FirearmAimRollDegrees = FClamp(R, -80, 80);
    return true;
}

// IsA used to hand any subclass its parent's authored grip, so stock variants
// that ship their own first-person rig (the HRG Kaboomstick under the double
// barrel, the HRG buckshot revolver under the SW500, the dummy pistol under the
// 9mm) were reported supported on grips nobody had checked against their mesh.
// Identity is now the exact class, plus the subclasses audited into the table
// above. Every profile class is itself concrete, so nothing else regresses.
simulated function int FindWeaponProfile(KFWeapon W)
{
    local int I, Index;
    if (W == None) return -1;
    Index = FindProfileByClassName(W.Class.Name);
    if (Index >= 0) return Index;
    for (I = 0; I < AuditedSubclasses.Length; ++I)
        if (AuditedSubclasses[I].SubclassName == W.Class.Name)
            return FindProfileByClassName(AuditedSubclasses[I].ProfileClassName);
    return -1;
}

simulated function bool Supported(KFWeapon W)
{
    return FindWeaponProfile(W) >= 0;
}

simulated function bool DispatchManagedWeapon(KFWeapon W, int EventCode)
{
    return HandInventory != None && HandInventory.DispatchWeapon(W, EventCode);
}

// The network package supplies this seam without making KF2VR depend on it.
simulated function bool UsesNetworkDualWeapons() { return false; }
simulated function bool RequestNetworkHands(KFWeapon Left, KFWeapon Right) { return false; }
simulated function bool RequestNetworkGrenade(KFWeapon ProjectileOwner, class<KFProj_Grenade> GrenadeClass,
    int Hand, vector Position, vector ReleaseVelocity) { return false; }
simulated function bool NetworkGrenadePending() { return false; }
simulated function bool RequestNetworkDosh(vector Position, vector ReleaseVelocity) { return false; }
simulated function bool RequestNetworkDeployable(KFWeapon W, int Hand, vector Position, vector ReleaseVelocity) { return false; }
simulated function int NetworkGrenadeCount() { return 0; }
simulated function bool ReadNetworkHands(out KFWeapon Left, out KFWeapon Right) { return false; }
simulated function bool RequestNetworkMeleeHit(byte FiringMode, Actor Victim, vector HitLocation, vector RayDir, name BoneName, KFWeapon SourceWeapon, optional float DamageScale = 1.0, optional bool bShieldContact)
{
    if (RootBridge != None) return RootBridge.RequestNetworkMeleeHit(FiringMode, Victim, HitLocation, RayDir, BoneName, SourceWeapon, DamageScale, bShieldContact);
    return false;
}
simulated function bool RequestNetworkSeekerSights(KFWeapon W, bool bSighted)
{
    if (RootBridge != None) return RootBridge.RequestNetworkSeekerSights(W, bSighted);
    return false;
}
simulated function bool RequestNetworkPhysicalDamage(Pawn Victim, float DamageAmount, vector HitLocation, vector Momentum, class<DamageType> DamageType, name BoneName, int Hand)
{
    if (RootBridge != None) return RootBridge.RequestNetworkPhysicalDamage(Victim, DamageAmount, HitLocation, Momentum, DamageType, BoneName, Hand);
    return false;
}
// A network client's fist guard asks its server to parry (VRFistGuard).
simulated function bool RequestNetworkFistParry(Pawn Victim, int Hand)
{
    if (RootBridge != None) return RootBridge.RequestNetworkFistParry(Victim, Hand);
    return false;
}
// Practice on a network client. The range itself lives on the server; these
// report its state and forward the practice page's commands to it.
simulated function bool NetworkPracticeAvailable()
{
    if (RootBridge != None) return RootBridge.NetworkPracticeAvailable();
    return false;
}
simulated function bool NetworkPracticeActive()
{
    if (RootBridge != None) return RootBridge.NetworkPracticeActive();
    return false;
}
simulated function bool NetworkPracticeInvulnerable()
{
    if (RootBridge != None) return RootBridge.NetworkPracticeInvulnerable();
    return false;
}
simulated function bool RequestNetworkPractice(string Command)
{
    if (RootBridge != None) return RootBridge.RequestNetworkPractice(Command);
    return false;
}
simulated function bool NetworkGodMode()
{
    if (RootBridge != None) return RootBridge.NetworkGodMode();
    return false;
}
simulated function bool RequestNetworkGodMode(bool bOn)
{
    if (RootBridge != None) return RootBridge.RequestNetworkGodMode(bOn);
    return false;
}
simulated function bool RequestNetworkKnockdown(KFPawn_Monster M, vector Nudge)
{
    if (RootBridge != None) return RootBridge.RequestNetworkKnockdown(M, Nudge);
    return false;
}
simulated function bool RequestNetworkReleaseGrab(KFPawn_Monster M, int Hand, optional vector Throw)
{
    if (RootBridge != None) return RootBridge.RequestNetworkReleaseGrab(M, Hand, Throw);
    return false;
}
simulated function bool RequestNetworkGrabHold(KFPawn_Monster M, name BoneName, int Hand, vector Palm, rotator HandRotation)
{
    if (RootBridge != None) return RootBridge.RequestNetworkGrabHold(M, BoneName, Hand, Palm, HandRotation);
    return false;
}
simulated function bool RequestNetworkGrabMove(int Hand, vector Palm, rotator HandRotation)
{
    if (RootBridge != None) return RootBridge.RequestNetworkGrabMove(Hand, Palm, HandRotation);
    return false;
}

simulated function BeginMenuWorldRender()
{
    local GFxObject.ASDisplayInfo Display;
    EndMenuRender();
    RefreshMenuState();
    if (NativeMenuActive == 0 || PC.MyGFxManager.ManagerObject == None) return;
    MenuRenderManager = PC.MyGFxManager;
    MenuRenderViewport = LocalPlayer(PC.Player).ViewportClient;
    if (MenuRenderViewport == None) { MenuRenderManager = None; return; }
    MenuRenderRoot = MenuRenderManager.ManagerObject;
    Display = MenuRenderRoot.GetDisplayInfo();
    bMenuRenderRootVisible = Display.Visible;
    MenuRenderMovieHUD = PC.MyGFxHUD;
    if (MenuRenderMovieHUD != None)
    {
        MenuRenderHUDRoot = MenuRenderMovieHUD.KFGXHUDManager;
        if (MenuRenderHUDRoot != None)
        {
            Display = MenuRenderHUDRoot.GetDisplayInfo();
            bMenuRenderHUDVisible = Display.Visible;
        }
        bMenuRenderHUDDisable = MenuRenderMovieHUD.bDisableWorldRendering;
        bMenuRenderHUDCapture = MenuRenderMovieHUD.bCaptureWorldRendering;
    }
    MenuRenderHUD = PC.myHUD;
    if (MenuRenderHUD != None) bMenuRenderShowHUD = MenuRenderHUD.bShowHUD;
    bMenuRenderManagerDisable = MenuRenderManager.bDisableWorldRendering;
    bMenuRenderManagerCapture = MenuRenderManager.bCaptureWorldRendering;
    bMenuRenderViewportDisable = MenuRenderViewport.bDisableWorldRendering;
    bMenuRenderViewportCaptured = MenuRenderViewport.bCapturedWorldRendering;
    NativeMenuRenderStage = 1;
    // Hide the display trees, not the movie registration or input focus. The
    // viewport also scans each movie's world-render flags, so scope both.
    MenuRenderRoot.SetVisible(false);
    MenuRenderManager.bDisableWorldRendering = false;
    MenuRenderManager.bCaptureWorldRendering = false;
    if (MenuRenderHUDRoot != None) MenuRenderHUDRoot.SetVisible(false);
    if (MenuRenderMovieHUD != None)
    {
        MenuRenderMovieHUD.bDisableWorldRendering = false;
        MenuRenderMovieHUD.bCaptureWorldRendering = false;
    }
    if (MenuRenderHUD != None) MenuRenderHUD.bShowHUD = false;
    MenuRenderViewport.bDisableWorldRendering = false;
    MenuRenderViewport.bCapturedWorldRendering = false;
}

simulated function BeginMenuImageRender()
{
    if (NativeMenuRenderStage != 1 || MenuRenderManager == None || MenuRenderViewport == None) return;
    MenuRenderRoot.SetVisible(bMenuRenderRootVisible);
    MenuRenderManager.bDisableWorldRendering = true;
    MenuRenderManager.bCaptureWorldRendering = false;
    MenuRenderViewport.bDisableWorldRendering = true;
    MenuRenderViewport.bCapturedWorldRendering = false;
    NativeMenuRenderStage = 2;
}

simulated function EndMenuRender()
{
    if (NativeMenuRenderStage != 0)
    {
        NativeMenuRenderStage = 0;
        if (MenuRenderRoot != None) MenuRenderRoot.SetVisible(bMenuRenderRootVisible);
        if (MenuRenderHUDRoot != None) MenuRenderHUDRoot.SetVisible(bMenuRenderHUDVisible);
        if (MenuRenderManager != None)
        {
            MenuRenderManager.bDisableWorldRendering = bMenuRenderManagerDisable;
            MenuRenderManager.bCaptureWorldRendering = bMenuRenderManagerCapture;
        }
        if (MenuRenderMovieHUD != None)
        {
            MenuRenderMovieHUD.bDisableWorldRendering = bMenuRenderHUDDisable;
            MenuRenderMovieHUD.bCaptureWorldRendering = bMenuRenderHUDCapture;
        }
        if (MenuRenderHUD != None) MenuRenderHUD.bShowHUD = bMenuRenderShowHUD;
        if (MenuRenderViewport != None)
        {
            MenuRenderViewport.bDisableWorldRendering = bMenuRenderViewportDisable;
            MenuRenderViewport.bCapturedWorldRendering = bMenuRenderViewportCaptured;
        }
    }
    MenuRenderRoot = None;
    MenuRenderHUDRoot = None;
    MenuRenderManager = None;
    MenuRenderMovieHUD = None;
    MenuRenderHUD = None;
    MenuRenderViewport = None;
}

simulated function bool DispatchManagedSprint(bool bNewSprintStatus)
{
    return HandInventory != None && HandInventory.SetSprinting(bNewSprintStatus);
}

simulated function UpdateMedicTargetLock(KFWeap_MedicBase W)
{
    class'VRMedicTargeting'.static.Update(self, W);
}

simulated function bool UsesFirearmProfile(KFWeapon W)
{
    local int ProfileIndex;
    ProfileIndex = FindWeaponProfile(W);
    return ProfileIndex >= 0 && WeaponProfiles[ProfileIndex].bFirearm;
}

// -1 means ordinary stock handling (tools/unmanaged items), 0 hip, 1 sighted.
// Native captures this once per synchronous shot and reuses it for spread and
// recoil. The normal stock recoil integration asks for current grip policy too.
simulated function int GetWeaponHandlingPolicy(KFWeapon W)
{
    local int ProfileIndex, OtherHand;
    local VRWeaponRuntime R;
    if (NativeHandlingEnabled != 1 || NativeConnection == 0 || PC == None || Human == None
        || PC.Pawn != Human || !IsLocalVRContext() || W == None || W.bDeleteMe
        || W.Instigator != Human || W.InvManager != Human.InvManager) return -1;
    ProfileIndex = FindWeaponProfile(W);
    if (ProfileIndex < 0 || !WeaponProfiles[ProfileIndex].bFirearm) return -1;
    if (HeldInventory != None) R = HeldInventory.FindItem(W);
    if (R != None)
    {
        if (!R.IsCurrent() || R.PrimaryHand < 0 || R.PrimaryHand > 1
            || HeldInventory.GetPrimary(R.PrimaryHand) != R) return -1;
        if (WeaponProfiles[ProfileIndex].bOneHanded && !WeaponProfiles[ProfileIndex].bPistolBrace) return 1;
        if (R.HasValidSupport()) return 1;
        // A pistol in each hand is the dual stance stock aims down sights
        // with; neither hand is free to brace, so the pair counts as sighted
        // (Gunslinger Shoot'n'Move, sighted spread and recoil).
        return int(WeaponProfiles[ProfileIndex].bPistolBrace && IsHeldPistol(HeldInventory.GetPrimary(1 - R.PrimaryHand)));
    }
    if (W != ActiveWeapon || W != Human.Weapon || WeaponHand < 0 || WeaponHand > 1
        || Hands[WeaponHand].Item != W) return -1;
    if (WeaponProfiles[ProfileIndex].bOneHanded && !WeaponProfiles[ProfileIndex].bPistolBrace) return 1;
    OtherHand = 1 - WeaponHand;
    return int(bCalibrated && !IsWeaponReadying(W) && !bReadyPoseSettling
        && (NativeValidMask & 3) == 3 && (NativeGripActiveMask & 3) == 3 && (NativeGripMask & 3) == 3
        && Hands[WeaponHand].bGrip && Hands[OtherHand].bGrip && Hands[OtherHand].Item == None
        && Hands[OtherHand].SupportOwner == WeaponHand);
}

simulated function bool IsHeldPistol(VRWeaponRuntime R)
{
    local int ProfileIndex;
    if (R == None || R.Item == None || R.Item.bDeleteMe || !R.IsCurrent()) return false;
    ProfileIndex = FindWeaponProfile(R.Item);
    return ProfileIndex >= 0 && WeaponProfiles[ProfileIndex].bFirearm && WeaponProfiles[ProfileIndex].bOneHanded;
}

simulated function VRPerkContext GetPerkContext()
{
    if (PerkContext == None) PerkContext = new(self) class'VRPerkContext';
    PerkContext.Bind(Human);
    return PerkContext;
}

// Each held item's grip, kept current on this machine and, online, reported
// to the server whenever it changes: the server judges perks by it.
simulated function UpdatePerkGrips()
{
    local int Hand, Policy;
    local KFWeapon W;
    // A respawned body gets a new server ledger; resend at a low rate so a
    // lost or early report still converges.
    if (WorldInfo.RealTimeSeconds - SentGripTime > 2.0)
    {
        SentGripTime = WorldInfo.RealTimeSeconds;
        SentGripItem[0] = None; SentGripItem[1] = None;
    }
    for (Hand = 0; Hand < 2; ++Hand)
    {
        W = Hands[Hand].Item;
        Policy = W != None ? GetWeaponHandlingPolicy(W) : -1;
        if (W != None) GetPerkContext().SetGrip(W, Policy);
        if (W == SentGripItem[Hand] && Policy == SentGrip[Hand]) continue;
        if (W == None || RequestNetworkGrip(W, Policy) || WorldInfo.NetMode != NM_Client)
        {
            SentGripItem[Hand] = W;
            SentGrip[Hand] = Policy;
        }
    }
}

simulated function bool RequestNetworkGrip(KFWeapon W, int Policy)
{
    if (RootBridge != None) return RootBridge.RequestNetworkGrip(W, Policy);
    return false;
}

// Native: a managed item's FireAmmunition. Online clients only need the
// current-weapon half (client-side spread, Tight Choke); the authority also
// latches the grip the shot was fired with for its later hits.
simulated function NativePerkFire(KFWeapon W)
{
    local VRPerkContext C;
    C = GetPerkContext();
    if (W != None && W.Instigator == Human && W.InvManager == Human.InvManager)
    {
        C.SetGrip(W, GetWeaponHandlingPolicy(W));
        C.RecordShot(W);
    }
    C.Begin(W, C.ShotGrip(W));
}

// Native, authority only: a Zed's TakeDamage instigated by this player.
function NativePerkDamage(Actor Causer)
{
    local VRPerkContext C;
    local KFWeapon W;
    C = GetPerkContext();
    W = class'VRPerkContext'.static.ItemFromCauser(Causer);
    C.Begin(W, C.ShotGrip(W));
}

// Native, authority only: this pawn's UpdateGroundSpeed.
function NativePerkMovement()
{
    local VRPerkContext C;
    C = GetPerkContext();
    C.Begin(C.ChooseMovementItem(Hands[0].Item, Hands[1].Item), -1);
}

simulated function NativePerkEnd()
{
    if (PerkContext != None) PerkContext.End();
}

// The Seeker Six searches, guides and draws locks only while sighted. VR has
// no sight gesture, so LOCK-ON counts as sighted: the tracked barrel locks.
// The Rail Gun's targeting component likewise locks only while sighted, and
// only in its default AUTO mode (MANUAL has no targeting flags).
simulated function bool IsSeekerLockOn(KFWeapon W)
{
    return ((KFWeap_RocketLauncher_Seeker6(W) != None || KFWeap_HRG_Locust(W) != None) && W.bUseAltFireMode)
        || (KFWeap_Rifle_RailGun(W) != None && !W.bUseAltFireMode)
        || (KFWeap_SMG_G18(W) != None && bRiotShieldRaised);
}

// Riot Shield: stock raises the shield with iron sights, and only a raised
// shield blocks (AdjustDamage, server side). In VR the empty off hand raises
// it: lift that hand in front of the chest or face. Hysteresis keeps a hand
// held at the edge from flickering the block. The shield mesh already rides
// that hand (VRRiotShield), so the stock raise animation is not played: it
// would only turn the tracked Glock by up to 57 degrees.
simulated function UpdateRiotShield()
{
    local KFWeap_SMG_G18 W;
    local VRWeaponRuntime R;
    local int Off;
    local vector Forward, Rel;
    local rotator Facing;
    local bool bRaise;
    Off = -1;
    W = Human != None ? KFWeap_SMG_G18(Human.Weapon) : None;
    if (W != None && HeldInventory != None) R = HeldInventory.FindItem(W);
    if (R != None && R.PrimaryHand >= 0 && R.PrimaryHand <= 1 && W.IsInState('Active'))
    {
        Off = 1 - R.PrimaryHand;
        if (Hands[Off].Item == None && (NativeValidMask & (1 << Off)) != 0)
        {
            // Stock blocks within a cone of the body's facing, so measure there.
            Facing.Yaw = Human.Rotation.Yaw;
            Forward = vector(Facing);
            Rel = PalmPosition(Off) - HeadPosition;
            bRaise = (Rel dot Forward) > (bRiotShieldRaised ? 6.0 : 12.0)
                && Rel.Z > (bRiotShieldRaised ? -42.0 : -32.0);
        }
    }
    if (bRaise == bRiotShieldRaised && W == RiotShieldWeapon) return;
    // Lower a shield left behind by a weapon switch or a lost item.
    if (RiotShieldWeapon != None && RiotShieldWeapon != W && !RiotShieldWeapon.bDeleteMe && bRiotShieldRaised)
    {
        RiotShieldWeapon.bUsingSights = false;
        RequestNetworkSeekerSights(RiotShieldWeapon, false);
    }
    RiotShieldWeapon = W;
    if (bRaise == bRiotShieldRaised) return;
    bRiotShieldRaised = bRaise;
    if (W == None) return;
    W.bUsingSights = bRaise;
    RequestNetworkSeekerSights(W, bRaise);
    if (Off >= 0) class'VRMeleeControls'.static.Pulse(self, 1 << Off, bRaise ? 0.45 : 0.2, 0.04);
}

simulated function UpdateSeekerLockOn()
{
    local KFWeapon W;
    local bool bLock;
    if (Human == None || Human.InvManager == None) return;
    foreach Human.InvManager.InventoryActors(class'KFWeapon', W)
    {
        if (KFWeap_RocketLauncher_Seeker6(W) == None && KFWeap_HRG_Locust(W) == None
            && KFWeap_Rifle_RailGun(W) == None) continue;
        bLock = IsSeekerLockOn(W);
        if (W.bUsingSights == bLock) continue;
        W.bUsingSights = bLock;
        // The server guides the rocket, so it needs the flag too; stock
        // ServerZoomIn would also zoom the camera and play sight dialog.
        RequestNetworkSeekerSights(W, W.bUsingSights);
    }
}

// Return 1/2 for an applied scope's original false/true flag, 0 if unavailable.
// Script owns this packed bool layout; native never guesses its storage mask.
simulated function int ApplyBallisticSights(KFWeapon W, int Policy)
{
    local int Saved;
    if (NativeHandlingEnabled != 1 || W == None || W.bDeleteMe || Human == None
        || W.Instigator != Human || Policy < 0 || Policy > 1) return 0;
    Saved = 1 + int(W.bUsingSights);
    if (IsSeekerLockOn(W)) Policy = 1;
    W.bUsingSights = Policy == 1;
    ++NativeHandlingScopes;
    return Saved;
}

simulated function RestoreBallisticSights(KFWeapon W, int Saved)
{
    if (W == None || Saved < 1 || Saved > 2) { NativeHandlingFault = 1; return; }
    W.bUsingSights = Saved == 2;
    ++NativeHandlingRestores;
}

// KFProjectile.Init adds TossZ to the spawned velocity's world Z AFTER the aim
// direction is applied, so a stock grenade launcher leaves 150 over 4000, or
// 2.15 degrees, above the bore, and with GravityScale 0.5 it does not cross
// back down through that line until roughly 32 metres. A flat screen hides the
// offset inside crosshair convergence; a tracked beam marks the literal bore,
// so the whole shot reads as missing high. Take the toss back off the one
// projectile this shot just made: nothing global is touched, every pellet of a
// multi-shot spawn is handled on its own call, and nothing needs undoing.
//
// The projectile keeps its gravity. A grenade still falls, it just starts along
// the beam instead of above it.
//
// Thrown grenades keep their toss: the hand throws them, no beam claims where
// they go, and the arc is the weapon.
simulated function bool ClearProjectileToss(KFWeapon W, KFProjectile P)
{
    if (NativeHandlingEnabled != 1 || W == None || W.bDeleteMe || P == None || P.bDeleteMe
        || Human == None || W.Instigator != Human || P.Owner != W
        || W.CurrentFireMode == class'KFWeapon'.const.GRENADE_FIREMODE
        || P.TossZ == 0) return false;
    P.Velocity.Z -= P.TossZ;
    ++NativeTossSuppressions;
    return true;
}

simulated function bool GetSupportGripWorld(KFWeapon W, out vector GripPosition, out quat GripRotation)
{
    local name SupportBone;
    local quat SupportQ;
    if (W == None || W != ActiveWeapon || !bCalibrated || ActiveProfile < 0 || W.MySkelMesh == None)
        return false;
    SupportBone = WeaponProfiles[ActiveProfile].SupportBone;
    if (SupportBone == '') return false;
    SupportQ = W.MySkelMesh.GetBoneQuaternion(SupportBone);
    GripPosition = W.MySkelMesh.GetBoneLocation(SupportBone) + QuatRotateVector(SupportQ, SupportGripOffset);
    GripRotation = QuatProduct(SupportQ, SupportGripRotation);
    return true;
}

simulated function rotator ControllerAimRotation(rotator RawAim, KFWeapon W)
{
    local rotator Correction;
    if (!bUseQuest2GripProfile || !UsesFirearmProfile(W))
        return RawAim;
    // SteamVR Quest 2 aim already contributes -39.4 degrees relative to the
    // legacy raw pose. The user's KF1 firearm setting is -48: residual -8.6.
    // Postmultiply around the controller's local right axis, preserving roll.
    Correction.Pitch = int(FClamp(FirearmAimPitchDegrees, -80, 80) * 65536.0 / 360.0);
    Correction.Yaw = int(FClamp(FirearmAimYawDegrees, -80, 80) * 65536.0 / 360.0);
    Correction.Roll = int(FClamp(FirearmAimRollDegrees, -80, 80) * 65536.0 / 360.0);
    return QuatToRotator(QuatProduct(QuatFromRotator(RawAim), QuatFromRotator(Correction)));
}

simulated function MaterialInterface GetFloatingHandsMaterial()
{
    if (BakedHandsMaterial == None)
        BakedHandsMaterial = class'VRHUDPanel'.static.CreateHorzineMaterial(self, "VRHorzineHands");
    if (BakedHandsMaterial != None) return BakedHandsMaterial;
    return FloatingHandsMaterial;
}

simulated function InitializeFreeHands()
{
    local int I;
    local AnimTree Template;
    local AnimNodeSequence Seq;
    local SkelControlSingleBone Wrist;
    local SkelControl_TwistBone Twist1, Twist2;
    local AnimTree.SkelControlListHead Link, TwistLink1, TwistLink2;
    local name TwistBone1, TwistBone2;
    if (Human == None || (Arms == Human.ArmsMesh && ArmsTree != None)) return;
    RestoreFreeHandsOccluder();
    Arms = Human.ArmsMesh;
    if (Arms == None) return;
    OriginalFreeHandsOccluderMesh = Arms;
    bOriginalFreeHandsOccluder = Arms.bUseAsOccluder;
    // These near-face tracked meshes must not contribute world query depth.
    Arms.bUseAsOccluder = false;
    if (Arms.SkeletalMesh != FloatingHandsMesh) Arms.SetSkeletalMesh(FloatingHandsMesh);
    Arms.SetMaterial(0, GetFloatingHandsMaterial());
    // Empty hands have their own relaxed pose. Authored weapon finger poses
    // live only on the separate bound-hand components below.
    Arms.DetachFromAny();
    Arms.SetParentAnimComponent(None);
    Arms.bTransformFromAnimParent = 0;
    Arms.AnimSets.Length = 0;
    Arms.UpdateAnimations();
    Arms.SetFOV(0);
    Arms.bIgnoreControllersWhenNotRendered = false;
    SetOwner(Human);
    AttachComponent(Arms);
    Template = new(self) class'AnimTree';
    Seq = new(Template) class'AnimNodeSequence';
    Seq.NodeName = 'VRFreeHandReference';
    Seq.bNoNotifies = true;
    Seq.bPlaying = false;
    Template.Children[0].Anim = Seq;
    Template.Children[0].Weight = 1;
    for (I = 0; I < 2; ++I)
    {
        Wrist = new(Template) class'SkelControlSingleBone';
        Wrist.ControlName = I == 0 ? 'VRLeftWrist' : 'VRRightWrist';
        Wrist.ControlStrength = 0;
        Wrist.StrengthTarget = 0;
        Wrist.bApplyRotation = true;
        Wrist.bAddRotation = false;
        Wrist.BoneRotationSpace = BCS_WorldSpace;
        Wrist.bApplyTranslation = true;
        Wrist.bAddTranslation = false;
        Wrist.BoneTranslationSpace = BCS_WorldSpace;
        Wrist.bIgnoreWhenNotRendered = false;
        Link.BoneName = HandBone(I);
        Link.ControlHead = Wrist;
        Template.SkelControlLists.AddItem(Link);

        TwistBone1 = I == 0 ? 'LeftForeArmTwist1_1stP' : 'RightForeArmTwist1_1stP';
        if (Arms.MatchRefBone(TwistBone1) >= 0)
        {
            Twist1 = new(Template) class'SkelControl_TwistBone';
            Twist1.ControlName = I == 0 ? 'VRLeftForeArmTwist1' : 'VRRightForeArmTwist1';
            Twist1.ControlStrength = 1.0;
            Twist1.StrengthTarget = 1.0;
            Twist1.SourceBoneName = HandBone(I);
            Twist1.TwistAngleScale = -0.5;
            Twist1.bIgnoreWhenNotRendered = false;
            TwistLink1.BoneName = TwistBone1;
            TwistLink1.ControlHead = Twist1;
            Template.SkelControlLists.AddItem(TwistLink1);
        }

        TwistBone2 = I == 0 ? 'LeftForeArmTwist2_1stP' : 'RightForeArmTwist2_1stP';
        if (Arms.MatchRefBone(TwistBone2) >= 0)
        {
            Twist2 = new(Template) class'SkelControl_TwistBone';
            Twist2.ControlName = I == 0 ? 'VRLeftForeArmTwist2' : 'VRRightForeArmTwist2';
            Twist2.ControlStrength = 1.0;
            Twist2.StrengthTarget = 1.0;
            Twist2.SourceBoneName = HandBone(I);
            Twist2.TwistAngleScale = -0.25;
            Twist2.bIgnoreWhenNotRendered = false;
            TwistLink2.BoneName = TwistBone2;
            TwistLink2.ControlHead = Twist2;
            Template.SkelControlLists.AddItem(TwistLink2);
        }
    }
    if (FreeHandPose == None) FreeHandPose = new(self) class'VRFreeHandPose';
    FreeHandPose.BuildControls(Template);
    Arms.SetAnimTreeTemplate(Template);
    ArmsTree = AnimTree(Arms.Animations);
    IdlePose = AnimNodeSequence(Arms.FindAnimNode('VRFreeHandReference'));
    WristIK[0] = SkelControlSingleBone(Arms.FindSkelControl('VRLeftWrist'));
    WristIK[1] = SkelControlSingleBone(Arms.FindSkelControl('VRRightWrist'));
    Arms.ForceUpdate(false);
    if (!FreeHandPose.Bind(self)) `log("KF2VR_HANDS free-pose-unavailable reason=reference-rig");
    for (I = 0; I < 2; ++I)
        if (WristIK[I] != None) { WristIK[I].ControlStrength = 1; WristIK[I].StrengthTarget = 1; }
}

// Stock content loading marks project weapons (KF2VRSource/KF2VREngineer/
// KF2VRPortal meshes) loaded without assigning their first-person mesh:
// observed loaded=True mesh=None for both Source weapons. Resolve the named
// assets once, as the starter asset guard already does, before calibration.
simulated function ResolveFirstPersonContent(KFWeapon W)
{
    local SkeletalMesh Asset;
    local AnimSet Anims;
    local int I;
    if (!W.WeaponContentLoaded || W.MySkelMesh == None || W.MySkelMesh.SkeletalMesh != None
        || W.FirstPersonMeshName == "") return;
    Asset = SkeletalMesh(DynamicLoadObject(W.FirstPersonMeshName, class'SkeletalMesh', true));
    if (Asset == None) return;
    W.MySkelMesh.SetSkeletalMesh(Asset);
    if (W.MySkelMesh.AnimSets.Length == 0)
    {
        for (I = 0; I < W.FirstPersonAnimSetNames.Length; ++I)
        {
            Anims = AnimSet(DynamicLoadObject(W.FirstPersonAnimSetNames[I], class'AnimSet', true));
            if (Anims != None) W.MySkelMesh.AnimSets.AddItem(Anims);
        }
        W.MySkelMesh.UpdateAnimations();
    }
    `log("KF2VR_HANDS content-resolved weapon=" $ W.Class @ "mesh=" $ Asset @ "animSets=" $ W.MySkelMesh.AnimSets.Length);
}

simulated function ConfigureWeapon(KFWeapon W)
{
    local int I;

    if (W != None) ResolveFirstPersonContent(W);
    // Stock content streams in after GivenTo; a weapon that is not yet loaded
    // has no final skeleton and stock AttachWeaponTo also defers it. Present
    // no item until the mesh exists, instead of permanently rejecting its rig.
    if (W != None && (!W.WeaponContentLoaded || W.MySkelMesh == None || W.MySkelMesh.SkeletalMesh == None))
    {
        if (LoggedContentPendingWeapon != W)
        {
            LoggedContentPendingWeapon = W;
            `log("KF2VR_HANDS content-pending weapon=" $ W.Class @ "loaded=" $ W.WeaponContentLoaded
                @ "component=" $ W.MySkelMesh @ "mesh=" $ (W.MySkelMesh != None ? string(W.MySkelMesh.SkeletalMesh) : "None")
                @ "state=" $ W.GetStateName());
        }
        W = None;
    }
    if (W == ActiveWeapon) return;
    if (VRTrackedWeapon(ActiveWeapon) != None) VRTrackedWeapon(ActiveWeapon).CancelTrackedInput();
    // A deliberate two-hand hold survives an inventory transition. Keep the
    // intent through a transient None weapon, but require both physical grips
    // and tracked inputs to remain held until the next foregrip is ready.
    if (ActiveProfile >= 0 && ActiveWeapon != None
        && WeaponProfiles[ActiveProfile].SupportBone != ''
        && Hands[1 - WeaponHand].SupportOwner == WeaponHand)
        bCarrySupportGrip = true;
    if ((NativeGripMask & 3) != 3 || (NativeGripActiveMask & 3) != 3 || (NativeValidMask & 3) != 3)
        bCarrySupportGrip = false;
    ClearHandAttachments();
    HideWeaponLaser();
    bWasTwoHandedAim = false;
    bTwoHandReleaseSmoothing = false;
    RecoilKick = 0.0;
    RecoilKickPeak = 0.0;
    LastKickShotCount = -1;
    if (GripPoseMesh != None) { GripPoseMesh.DetachFromAny(); GripPoseMesh = None; }
    if (ActiveWeapon != None)
    {
        RestoreWeaponMotion();
        RestoreWeaponRendering();
        if (ActiveProfile >= 0 && ActiveWeapon.MySkelMesh != None)
            ActiveWeapon.MySkelMesh.bForceUpdateAttachmentsInTick = bOriginalForceAttachmentsInTick;
        ActiveWeapon.StopFire(0);
        ActiveWeapon.StopFire(1);
        ActiveWeapon.StopFire(2);
        class'VRBurstFireControl'.static.CancelAction(ActiveWeapon);
        class'VRFlamePresentation'.static.CancelAction(ActiveWeapon);
        if (ActiveWeapon.IsA('KFWeap_MeleeBase')) ActiveWeapon.StopFire(5);
        ActiveWeapon.SetIronSights(false);
        ActiveWeapon.RecoilViewRotationScale = OriginalViewRecoil;
        ActiveWeapon.SuppressRecoilViewRotationScale = OriginalSuppressionViewRecoil;
        if (KFWeap_Shotgun_DoubleBarrel(ActiveWeapon) != None)
            KFWeap_Shotgun_DoubleBarrel(ActiveWeapon).DoubleBarrelKickMomentum = OriginalDoubleBarrelKickMomentum;
    }
    for (I = 0; I < 2; ++I)
    {
        Hands[I].Item = None;
        Hands[I].SupportOwner = -1;
        Hands[I].bTrigger = false;
        Hands[I].bTriggerArmed = false;
    }
    ActiveWeapon = W;
    ActiveProfile = FindWeaponProfile(W);
    if (W != None && (ActiveProfile < 0 || WeaponProfiles[ActiveProfile].SupportBone == ''))
        bCarrySupportGrip = false;
    bCalibrated = false;
    bReadyPoseSettling = true;
    bSprintPoseSettling = false;
    bGripReferenceChecked = false;
    NativeWeaponReady = 0;
    if (W != None)
    {
        OriginalViewRecoil = W.RecoilViewRotationScale;
        OriginalSuppressionViewRecoil = W.SuppressRecoilViewRotationScale;
        if (KFWeap_Shotgun_DoubleBarrel(W) != None)
            OriginalDoubleBarrelKickMomentum = KFWeap_Shotgun_DoubleBarrel(W).DoubleBarrelKickMomentum;
    }
    if (ActiveProfile < 0 || W.MySkelMesh == None) return;
    if (W.MySkelMesh.MatchRefBone(WeaponProfiles[ActiveProfile].RootBone) < 0
        || W.MySkelMesh.MatchRefBone(HandBone(0)) < 0 || W.MySkelMesh.MatchRefBone(HandBone(1)) < 0
        || (WeaponProfiles[ActiveProfile].SupportBone != ''
            && W.MySkelMesh.MatchRefBone(WeaponProfiles[ActiveProfile].SupportBone) < 0))
    {
        `log("KF2VR_HANDS profile-invalid weapon=" $ W.Class @ "reason=missing-grip-bone"
            @ "mesh=" $ W.MySkelMesh.SkeletalMesh @ "root=" $ W.MySkelMesh.MatchRefBone(WeaponProfiles[ActiveProfile].RootBone)
            @ "left=" $ W.MySkelMesh.MatchRefBone(HandBone(0)) @ "right=" $ W.MySkelMesh.MatchRefBone(HandBone(1))
            @ "support=" $ W.MySkelMesh.MatchRefBone(WeaponProfiles[ActiveProfile].SupportBone));
        ActiveProfile = -1;
        return;
    }
    ConfigureWeaponRendering(W);
    if (WeaponProfiles[ActiveProfile].bFirearm || W.IsA('KFWeap_MeleeBase'))
    {
        bOriginalAdditiveMoveAnim = W.bUseAdditiveMoveAnim;
        bOriginalWeaponTilt = W.bEnableTiltSkelControl;
        bWeaponMotionConfigured = true;
        EnforceWeaponMotion(W);
    }
    bOriginalForceAttachmentsInTick = W.MySkelMesh.bForceUpdateAttachmentsInTick;
    W.MySkelMesh.bForceUpdateAttachmentsInTick = true;
    // Recoil remains in the gun buffer; do not add its camera component to
    // tracked head orientation or the body's locomotion heading.
    W.RecoilViewRotationScale = 0;
    W.SuppressRecoilViewRotationScale = 0;
    if (KFWeap_Shotgun_DoubleBarrel(W) != None)
    {
        // The stock double shot launches the pawn backward. Keep this comfort
        // prototype stationary while preserving gun recoil, pellets and ammo.
        KFWeap_Shotgun_DoubleBarrel(W).DoubleBarrelKickMomentum = 0;
        `log("KF2VR_HANDS double-barrel kickMomentum=0 alt=RightGrip+RightTrigger");
    }
    Hands[WeaponHand].Item = W;
    if (RootBridge != None)
    {
        Arms = RootBridge.Arms;
        ArmsTree = RootBridge.ArmsTree;
        FreeHandPose = RootBridge.FreeHandPose;
        WristIK[0] = RootBridge.WristIK[0];
        WristIK[1] = RootBridge.WristIK[1];
    }
    else InitializeFreeHands();
    CalibrateGripPose(W);
    if (bCalibrated && WeaponProfiles[ActiveProfile].bPhysicalMelee)
    {
        PhysicalMelee = new(self) class'VRPhysicalMelee';
        PhysicalMelee.Initialize(self, W);
    }
    // A physically swung melee gun (Mosin, Eviscerator) already strikes with its
    // measured head; a second bash contact would double its hits.
    if (bCalibrated && !WeaponProfiles[ActiveProfile].bPhysicalMelee
        && (WeaponProfiles[ActiveProfile].bFirearm || (W != None && !W.IsA('KFWeap_MeleeBase'))))
    {
        PhysicalBash = new(self) class'VRPhysicalBash';
        PhysicalBash.Initialize(self, W);
    }
    if (bCalibrated && VRTrackedPresentation(W) != None) VRTrackedPresentation(W).ConfigureTrackedPresentation(self);
    if (bCalibrated && RiotShield != None && !RiotShield.Calibrate(GripPoseMesh, HandBone(0)))
        `log("KF2VR_RIOTSHIELD calibration-unavailable weapon=" $ W.Class);
    `log("KF2VR_HANDS configured weapon=" $ W.Class @ "arms=" $ Arms
        @ "directWrists=" $ (WristIK[0] != None && WristIK[1] != None));
    `log("KF2VR_HANDS style=floating mesh=" $ Arms.SkeletalMesh
        @ "material=" $ Arms.GetMaterial(0) @ "armSolvers=false");
    `log("KF2VR_HANDS controllerProfile=Quest2 weapon=" $ W.Class @ "enabled=" $ bUseQuest2GripProfile
        @ "firearmLocalPitch=" $ FirearmAimPitchDegrees
        @ "applied=" $ (bUseQuest2GripProfile && FirearmAimPitchDegrees != 0
            && UsesFirearmProfile(W)));
}

// Actual item identity is explicit so the dual-wield dispatcher can resolve
// this same capability for either hand when its ownership refactor lands.
simulated function ResolveRPGBackBlast(KFWeap_RocketLauncher_RPG7 W)
{
    NativeBackBlastReady = int(class'VRLauncherSupport'.static.ResolveBackBlast(
        self, W, NativeBackBlastLocation, NativeBackBlastRotation));
}

simulated function UpdateSpatialHUD()
{
    HudWeaponMask = int(GetHUDWeapon(0) != None) | (int(GetHUDWeapon(1) != None) << 1);
    if (SpatialHUD == None) return;
    SpatialHUD.UpdateDisplay();
}

// Called only after native pose fields are published. Ordinary script Tick
// cannot renew the tracking receipt by repeatedly placing an old HUD pose.
simulated function RecordHUDSample()
{
    HudTrackingTime = WorldInfo.RealTimeSeconds;
}

// HUD ownership follows actual held objects. Supporting the other hand's gun
// is not a second weapon, and stock paired-pistol ammo is never split in half.
// Future dual-wield gameplay supplies distinct Hands[I].Item instances here.
simulated function KFWeapon GetHUDWeapon(int HandIndex)
{
    if (WeaponHand < 0 || WeaponHand > 1 || HandIndex < 0 || HandIndex > 1 || Hands[HandIndex].SupportOwner >= 0) return None;
    if (Hands[HandIndex].Item == None || Hands[HandIndex].Item.bDeleteMe) return None;
    if (HandIndex != WeaponHand && Hands[HandIndex].Item == Hands[WeaponHand].Item) return None;
    return Hands[HandIndex].Item;
}

simulated function SuspendSpatialHUD()
{
    if (SpatialHUD != None) SpatialHUD.SuspendHUD();
}

simulated function RestoreWeaponRendering()
{
    if (PhysicalMelee != None) { PhysicalMelee.Release(); PhysicalMelee = None; }
    if (PhysicalBash != None) { PhysicalBash.Release(); PhysicalBash = None; }
    if (AF2011Barrels != None) { AF2011Barrels.Release(false); AF2011Barrels = None; }
    if (RiotShield != None) { RiotShield.Release(); RiotShield = None; }
    if (M14Scope != None) { M14Scope.Release(false); M14Scope = None; }
    if (ActiveWeapon != None && ActiveWeapon.MySkelMesh != None && OriginalWeaponMaterials.Length > 0)
    {
        if (ActiveWeapon.MySkelMesh.bUseAsOccluder != bOriginalWeaponOccluder)
        {
            ActiveWeapon.MySkelMesh.bUseAsOccluder = bOriginalWeaponOccluder;
            ActiveWeapon.MySkelMesh.ForceUpdate(false);
        }
        ActiveWeapon.MySkelMesh.SetDepthPriorityGroup(OriginalWeaponDepthGroup);
        ActiveWeapon.MySkelMesh.SetViewOwnerDepthPriorityGroup(bOriginalWeaponOwnerDepth, OriginalWeaponOwnerDepthGroup);
        // Stock overrides also restore attached cartridge meshes (SW500).
        ActiveWeapon.SetFOV(OriginalWeaponFOV);
    }
    if (CartridgeRendering != None) CartridgeRendering.Restore();
    if (ReloadMeshPresentation != None) { ReloadMeshPresentation.Suspend(); ReloadMeshPresentation = None; }
    NativeReloadMagScale = 0;
    NativeReloadMagBoneCount = 0;
    // The stock flame SetFOV override updates pool zero twice. Restore both
    // pools and each pilot/spine particle from this presenter's own snapshot.
    if (FlameRendering != None) FlameRendering.Restore();
    if (M14Laser != None) { M14Laser.Release(false); M14Laser = None; }
    OriginalWeaponMaterials.Length = 0;
    NativeKeepWorldDepth = 0;
}

simulated function ConfigureWeaponRendering(KFWeapon W)
{
    local int I;
    if (W.IsA('KFWeap_Pistol_AF2011'))
    {
        AF2011Barrels = new(self) class'VRAF2011Barrels';
        AF2011Barrels.Capture(W);
    }
    // Binds lazily in PlaceWeapon: the live tree is not initialised on equip.
    // The same off-hand control carries the Bone Crusher's shield and the left
    // gauntlet of the Static Strikers and HRG Blast Brawlers, all on LW_Weapon.
    if (KFWeap_SMG_G18(W) != None || KFWeap_Blunt_MaceAndShield(W) != None
        || KFWeap_Blunt_PowerGloves(W) != None || KFWeap_HRG_BlastBrawlers(W) != None)
        RiotShield = new(self) class'VRRiotShield';
    if (W.IsA('KFWeap_Revolver_SW500') || W.IsA('KFWeap_Revolver_Rem1858'))
    {
        if (CartridgeRendering == None) CartridgeRendering = new(self) class'VRCartridgeRendering';
        CartridgeRendering.Capture(W);
    }
    if (ReloadMeshPresentation == None) ReloadMeshPresentation = new(self) class'VRReloadMeshPresentation';
    // Arm only. The weapon mesh is not tick-initialised on the equip frame and
    // hiding a bone on it there crashed the player spawn; PlaceWeapon captures
    // on the next frame instead.
    ReloadMeshPresentation.Arm(W);
    OriginalWeaponDepthGroup = W.MySkelMesh.DepthPriorityGroup;
    OriginalWeaponOwnerDepthGroup = W.MySkelMesh.ViewOwnerDepthPriorityGroup;
    bOriginalWeaponOwnerDepth = W.MySkelMesh.bUseViewOwnerDepthPriorityGroup;
    bOriginalWeaponOccluder = W.MySkelMesh.bUseAsOccluder;
    OriginalWeaponFOV = W.MySkelMesh.FOV;
    if (W.IsA('KFWeap_FlameBase'))
    {
        if (FlameRendering == None) FlameRendering = new(self) class'VRFlamePresentation';
        FlameRendering.StockFOV = OriginalWeaponFOV;
        FlameRendering.Capture(W);
    }
    OriginalWeaponMaterials.Length = W.MySkelMesh.GetNumElements();
    for (I = 0; I < OriginalWeaponMaterials.Length; ++I)
        OriginalWeaponMaterials[I] = W.MySkelMesh.GetMaterial(I);
    if (W.Class.Name == 'KFWeap_Rifle_M14EBR')
    {
        M14Laser = new(self) class'VRM14Laser';
        M14Laser.StockFOV = OriginalWeaponFOV;
        M14Laser.Capture(W);
        M14Scope = new(self) class'VRM14Scope';
        if (!M14Scope.Initialize(self, W)) { M14Scope = None; `log("KF2VR_M14 scope-unavailable"); }
    }
    else if (W.Class.Name == 'KFWeap_AssaultRifle_FNFal')
    {
        M14Scope = new(self) class'VRM14Scope';
        if (!M14Scope.Initialize(self, W)) { M14Scope = None; `log("KF2VR_FNFAL scope-unavailable"); }
    }
    else if (W.Class.Name == 'KFWeap_Rifle_M99' || W.Class.Name == 'KFWeap_Rifle_RailGun'
        || W.Class.Name == 'KFWeap_Rifle_HRGIncision' || W.Class.Name == 'KFWeap_HVStormCannon'
        || W.Class.Name == 'KFWeap_HRG_CranialPopper'
        || W.Class.Name == 'KFWeap_Bow_Crossbow' || W.Class.Name == 'KFWeap_Rifle_ParasiteImplanter'
        || W.Class.Name == 'KFWeap_AssaultRifle_FAMAS' || W.Class.Name == 'KFWeap_HRG_Crossboom')
    {
        M14Scope = new(self) class'VRM14Scope';
        if (!M14Scope.Initialize(self, W)) { M14Scope = None; `log("KF2VR_SCOPE scope-unavailable" @ W.Class.Name); }
    }
    // Keep the complete stock 1P material instances, including their blood,
    // skin, reflection and custom lighting parameters. Native preserves world
    // depth through this mesh's original forward lighting pass.
    `log("KF2VR_HANDS weapon-rendering weapon=" $ W.Class @ "materials=" $ OriginalWeaponMaterials.Length
        @ "shader=stock-first-person");
}

simulated function bool HasOriginalWeaponMaterials(KFWeapon W)
{
    local int I;
    if (OriginalWeaponMaterials.Length == 0 || OriginalWeaponMaterials.Length != W.MySkelMesh.GetNumElements()) return false;
    for (I = 0; I < OriginalWeaponMaterials.Length; ++I)
    {
        // The optic uses a private child of its stock material so capture
        // parameters never mutate a shared or original lens instance.
        if (M14Scope != None && I == M14Scope.Weapon.ScopeMICIndex
            && W.MySkelMesh.GetMaterial(I) == M14Scope.Lens
            && M14Scope.Lens.Parent == M14Scope.OriginalLens) continue;
        if (W.MySkelMesh.GetMaterial(I) != OriginalWeaponMaterials[I]) return false;
    }
    return true;
}

// Called after the local camera finishes its stock update, including native
// camera animations/modifiers that bypass scripted shake entry points. Keep
// the living first-person view on the controller and the pawn's smoothed eye
// position; stereo applies the tracked HMD pose on top. Menus, death and other
// view targets retain their separate camera lifecycle.
simulated function EnforceCameraComfort()
{
    if (!IsLocalVRContext() || !bNativeEnabled
        || PC == None || !PC.IsLocalController() || Human == None || Human.Health <= 0 || PC.Pawn != Human
        || PC.PlayerCamera == None || PC.PlayerCamera.ViewTarget.Target != Human
        || !PC.UsingFirstPersonCamera()) return;
    if (Normalize(PC.PlayerCamera.CameraCache.POV.Rotation - PC.Rotation) != rot(0,0,0)
        || VSize(PC.PlayerCamera.CameraCache.POV.Location - VREyeLocation()) > 0.0001)
        ++CameraComfortCorrections;
    PC.PlayerCamera.CameraCache.POV.Rotation = PC.Rotation;
    PC.PlayerCamera.CameraCache.POV.Location = VREyeLocation();
    // VRComfortEffects captures cosmetic lens lifetimes before removal at the
    // viewport boundary. Removing them here would lose lens-only blood cues.
}

// Sample the authored grip on an independent, non-playing Idle skeleton.
// Sampling the live mesh during Equip captures an animated/tweened hand pose;
// waiting for its Idle leaves the entire first equip outside tracked control.
// This component never renders, emits notifies, or modifies the stock tree.
simulated function CalibrateGripPose(KFWeapon W)
{
    local AnimTree Template;
    local AnimNodeSequence Seq;
    local vector RootPos, HandPos, SupportPos;
    local quat RootQ, HandQ, SupportQ;
    local int I;
    local name RootBone, SupportBone;
    SupportPoseAnimSets.Length = 0;
    Template = new(self) class'AnimTree';
    Seq = new(Template) class'AnimNodeSequence';
    Seq.NodeName = 'VRGripReference';
    Seq.bNoNotifies = true;
    Template.Children[0].Anim = Seq;
    Template.Children[0].Weight = 1;
    GripPoseMesh = new(self) class'KFSkeletalMeshComponent';
    GripPoseMesh.SetSkeletalMesh(W.MySkelMesh.SkeletalMesh);
    GripPoseMesh.AnimSets = W.MySkelMesh.AnimSets;
    GripPoseMesh.bUpdateSkelWhenNotRendered = true;
    GripPoseMesh.bTickAnimNodesWhenNotRendered = true;
    GripPoseMesh.SetHidden(true);
    GripPoseMesh.SetAnimTreeTemplate(Template);
    Seq = AnimNodeSequence(GripPoseMesh.FindAnimNode('VRGripReference'));
    if (Seq == None) return;
    Seq.SetAnim(WeaponProfiles[ActiveProfile].IdleAnimation);
    if (Seq.AnimSeq == None) return;
    Seq.SetPosition(0, false);
    Seq.bPlaying = false;
    AttachComponent(GripPoseMesh);
    // A full attachment initializes this fresh skeleton; subsequent live
    // placement only needs transform updates and leaves animation evaluation.
    GripPoseMesh.ForceUpdate(false);
    RootBone = WeaponProfiles[ActiveProfile].RootBone;
    SupportBone = WeaponProfiles[ActiveProfile].SupportBone;
    RootPos = GripPoseMesh.GetBoneLocation(RootBone);
    RootQ = GripPoseMesh.GetBoneQuaternion(RootBone);
    IdleRootPosition = GripPoseMesh.GetBoneLocation(RootBone, 1);
    IdleRootRotation = GripPoseMesh.GetBoneQuaternion(RootBone, 1);
    for (I = 0; I < 2; ++I)
    {
        HandPos = GripPoseMesh.GetBoneLocation(HandBone(I));
        HandQ = GripPoseMesh.GetBoneQuaternion(HandBone(I));
        GripInWeapon[I] = QuatRotateVector(QuatInvert(RootQ), HandPos - RootPos);
        GripRotationInWeapon[I] = QuatProduct(QuatInvert(RootQ), HandQ);
    }
    SupportGripOffset = vect(0,0,0);
    SupportGripRotation = QuatFromRotator(rot(0,0,0));
    for (I = 0; I < 2; ++I)
    {
        SupportGripOffsetInWeapon[I] = vect(0,0,0);
        SupportGripRotationInWeapon[I] = QuatFromRotator(rot(0,0,0));
    }
    if (SupportBone != '')
    {
        SupportPos = GripPoseMesh.GetBoneLocation(SupportBone);
        SupportQ = GripPoseMesh.GetBoneQuaternion(SupportBone);
        for (I = 0; I < 2; ++I)
        {
            SupportGripOffsetInWeapon[I] = QuatRotateVector(QuatInvert(SupportQ),
                GripPoseMesh.GetBoneLocation(HandBone(I)) - SupportPos);
            SupportGripRotationInWeapon[I] = QuatProduct(QuatInvert(SupportQ),
                GripPoseMesh.GetBoneQuaternion(HandBone(I)));
        }
    }
    // Fan-hammer pistols have no authored wrap grip. Borrow only the stock
    // 9mm's support pose, fitted to this gun's unchanged primary wrist.
    if (WeaponProfiles[ActiveProfile].bUseSharedPistolBrace)
    {
        if (!class'VRPistolBracePose'.static.Calibrate(self)) return;
        // The donor pose replaces the fan-hammer support, including the
        // role-indexed snapshot used on future equips and left-hand binding.
        SupportGripOffsetInWeapon[0] = SupportGripOffset;
        SupportGripRotationInWeapon[0] = SupportGripRotation;
    }
    // Fire Axe and Abomination Axe author the left wrist at the lower butt
    // grip and the right at the upper shaft. Use the lower hand as primary so
    // tracked placement seats the axe by the handle rather than under its head.
    if (WeaponProfiles[ActiveProfile].bPhysicalLowerHandlePrimary)
    {
        PrimaryGrip = GripInWeapon[0];
        SupportGrip = GripInWeapon[1];
        SupportGripOffset = SupportGripOffsetInWeapon[1];
        SupportGripRotation = SupportGripRotationInWeapon[1];
    }
    else
    {
        PrimaryGrip = GripInWeapon[1];
        SupportGrip = GripInWeapon[0];
        SupportGripOffset = SupportGripOffsetInWeapon[0];
        SupportGripRotation = SupportGripRotationInWeapon[0];
    }
    bCalibrated = true;
    NativeWeaponReady = 1;
    `log("KF2VR_HANDS grip-calibrated weapon=" $ W.Class @ "right=" $ GripInWeapon[1]
        @ "left=" $ GripInWeapon[0] @ "supportBone=" $ SupportBone @ "supportOffset=" $ SupportGripOffset
        @ "pose=" $ Seq.AnimSeqName @ "source=independent-idle state=" $ W.GetStateName());
}

simulated function bool IsWeaponReadying(KFWeapon W)
{
    return W != None && (W.IsInState('WeaponEquipping') || W.IsInState('WeaponPuttingDown')
        || W.IsInState('WeaponAbortEquip'));
}

simulated function bool IsIdleWeaponAnimation(KFWeapon W)
{
    local name Sequence;
    if (W == None || W.WeaponAnimSeqNode == None || ActiveProfile < 0) return false;
    Sequence = W.WeaponAnimSeqNode.AnimSeqName;
    return Sequence == WeaponProfiles[ActiveProfile].IdleAnimation
        || W.IdleAnims.Find(Sequence) != INDEX_NONE || W.IdleSightedAnims.Find(Sequence) != INDEX_NONE;
}

// Reproduce stock's own resolution order for the node its live mesh evaluates:
// KFWeapon.PostInitAnimTree takes 'WeaponSeq', and Weapon.GetWeaponAnimNodeSeq
// falls back to the tree's first child, or to a legacy treeless sequence.
// Returning None means the live node could not be identified, never that the
// cached one is wrong.
simulated function AnimNodeSequence ResolveLiveWeaponAnimNode(KFWeapon W)
{
    local AnimNodeSequence Live;
    local AnimTree Tree;
    if (W == None || W.MySkelMesh == None) return None;
    Live = AnimNodeSequence(W.MySkelMesh.FindAnimNode('WeaponSeq'));
    if (Live != None) return Live;
    Tree = AnimTree(W.MySkelMesh.Animations);
    if (Tree != None)
    {
        if (Tree.Children.Length > 0) return AnimNodeSequence(Tree.Children[0].Anim);
        return None;
    }
    return AnimNodeSequence(W.MySkelMesh.Animations);
}

// KFWeapon caches WeaponAnimSeqNode once and only re-resolves it in Activate
// when the cache is None, so a stow's DetachComponent and the redraw's
// AttachComponent can leave that pointer on an orphaned node still reporting
// the sequence the gun was put away on, while the live skeleton evaluates a
// freshly initialised tree. Claim staleness only when a different live node is
// positively identified: an unresolvable one keeps the stock cache and its
// behaviour rather than silently disabling action motion for that weapon.
simulated function bool HasStaleWeaponAnimNode(KFWeapon W)
{
    local AnimNodeSequence Cached, Live;
    if (W == None || W.WeaponAnimSeqNode == None) return false;
    Cached = W.WeaponAnimSeqNode;
    Live = ResolveLiveWeaponAnimNode(W);
    return Live != None && Live != Cached;
}

// A physical reload (VRInteractiveReload) leaves the gun where the player holds
// it: they turn it over and work it themselves. Parts still animate.
simulated function bool InteractiveReloadHolds(KFWeapon W)
{
    local VRHandsBridge Root;
    Root = RootBridge != None ? RootBridge : self;
    return Root.HandInventory != None && Root.HandInventory.Input != None
        && Root.HandInventory.Input.Reloads != None && Root.HandInventory.Input.Reloads.HoldsPose(W);
}

// A healer's team clips reach the syringe out toward the patient, which reads
// correctly on a tracked hand and stays. The self-heal clips instead swing the
// whole weapon root back toward the desktop chest pose, so on a tracked hand
// the wrist appears to rotate backwards into the player. Drop the root rotation
// for those alone; the plunger and needle still animate, and healing a teammate
// keeps its authored swing.
simulated function bool IsSelfHealAnimation(KFWeapon W)
{
    local name Sequence;
    if (KFWeap_HealerBase(W) == None || W.WeaponAnimSeqNode == None
        || W.WeaponAnimSeqNode.AnimSeq == None || HasStaleWeaponAnimNode(W)) return false;
    Sequence = W.WeaponAnimSeqNode.AnimSeqName;
    return Sequence == class'KFWeap_HealerBase'.const.HealSelfAnim
        || Sequence == class'KFWeap_HealerBase'.const.HealSelfReloadAnim
        || Sequence == class'KFWeap_HealerBase'.const.QuickHealAnim;
}

simulated function bool IsPassiveWeaponAnimation(KFWeapon W)
{
    local name Sequence;
    if (W == None || (!UsesFirearmProfile(W) && !W.IsA('KFWeap_MeleeBase'))) return false;
    if (IsIdleWeaponAnimation(W) || W.IsInState('WeaponSprinting')) return true;
    if (W.WeaponAnimSeqNode == None) return true;
    // An orphaned cache names an action the live skeleton is not playing. Its
    // sequence is not evidence of one, so it cannot authorise the action delta.
    if (HasStaleWeaponAnimNode(W)) return true;
    // A just-attached mesh, and one stowed and redrawn, carries a sequence node
    // holding no animation. Its evaluated pose is the skeleton's reference pose,
    // not the authored idle CalibrateGripPose sampled for IdleRootRotation, so
    // composing an action delta against it rotates the gun and the hands
    // attached to it by the difference between the two and holds that error
    // until the next ConfigureWeapon. An empty node is not a deliberate action.
    if (W.WeaponAnimSeqNode.AnimSeq == None) return true;
    Sequence = W.WeaponAnimSeqNode.AnimSeqName;
    // Stock put-down and aborted equips leave their last frame on the node:
    // PutAway holds the gun lowered and turned ~90 degrees. When a trader sale
    // hands the 9mm back without a fresh equip, that frame would be composed
    // as an action and turn the gun and its hand until the next weapon swap.
    // The readying states are handled above; outside them these are leftovers.
    if (Sequence == W.GetWeaponPutDownAnimName() || Sequence == W.GetEquipAnimName()) return true;
    // The sprint outro can continue in Active. Inspect also runs in Active,
    // so the state alone cannot distinguish deliberate actions from sway.
    return Sequence == W.GetSprintStartAnimName() || Sequence == W.GetSprintLoopAnimName()
        || Sequence == W.GetSprintEndAnimName();
}

simulated function EnforceWeaponMotion(KFWeapon W)
{
    local bool bPoseChanged;
    if (!bWeaponMotionConfigured || W != ActiveWeapon) return;
    // Stock Active.BeginState and animation notifies can restore these layers.
    // Keep the movement-only additive off during actions as well as idle.
    bPoseChanged = W.bEnableTiltSkelControl;
    W.bEnableTiltSkelControl = false;
    W.bUseAdditiveMoveAnim = false;
    if (W.IdleBobBlendNode != None)
    {
        bPoseChanged = bPoseChanged || W.IdleBobBlendNode.Child2Weight != 0;
        W.ToggleAdditiveBobAnim(false, 0);
    }
    // Automatic fidgets and reload-button inspections share the same clips.
    // Remove only the automatic timer; preserve CanReload's explicit request.
    W.ClearTimer('IdleFidgetTimer');
    if (IsIdleWeaponAnimation(W))
    {
        // An action can return to Idle at time zero before its cached bones
        // have changed. Refresh that first idle pose as well as later time edits.
        bPoseChanged = bPoseChanged || !bIdlePoseFrozen || W.WeaponAnimSeqNode.CurrentTime != 0;
        W.WeaponAnimSeqNode.SetPosition(0, false);
        W.WeaponAnimSeqNode.bPlaying = false;
        bIdlePoseFrozen = true;
    }
    else bIdlePoseFrozen = false;
    // A transform-only update can retain the previous idle pose for the pump
    // or barrel attachment. Refresh the skeleton when a passive layer changes.
    // Action sequences, tween timing, empty-mag locks and notifies stay stock.
    if (bPoseChanged && W.MySkelMesh != None) W.MySkelMesh.ForceSkelUpdate();
}

simulated function RestoreWeaponMotion()
{
    if (!bWeaponMotionConfigured || ActiveWeapon == None) return;
    ActiveWeapon.bUseAdditiveMoveAnim = bOriginalAdditiveMoveAnim;
    ActiveWeapon.bEnableTiltSkelControl = bOriginalWeaponTilt;
    if (bIdlePoseFrozen && IsIdleWeaponAnimation(ActiveWeapon)) ActiveWeapon.WeaponAnimSeqNode.bPlaying = true;
    if (ActiveWeapon.IsInState('Active'))
    {
        ActiveWeapon.StartIdleFidgetTimer();
        ActiveWeapon.ToggleAdditiveBobAnim(!ActiveWeapon.bUsingSights);
    }
    bWeaponMotionConfigured = false;
    bIdlePoseFrozen = false;
}

simulated function ClearHandAttachments()
{
    local int I;
    for (I = 0; I < 2; ++I)
    {
        if (AttachedHands[I] != None)
        {
            AttachedHands[I].DetachFromAny();
            AttachedHands[I] = None;
        }
        if (Arms != None && AttachedHandBones[I] != '') Arms.UnHideBoneByName(HandBone(I));
        AttachedHandBones[I] = '';
    }
}

// A physical reload hides the free hand and draws its own on the slide or
// ammunition, away from the tracked wrist the hidden Arms bone still follows.
simulated function VRReloadHandPose ReloadDrawnHand(int I)
{
    local VRInteractiveReload Reloads;
    if (RootBridge != None || HandInventory == None || HandInventory.Input == None) return None;
    Reloads = HandInventory.Input.Reloads;
    if (Reloads == None || Reloads.ReloadHand == None || !Reloads.ReloadHand.bVisible
        || Reloads.ReloadHand.Hand != I || !Reloads.CoversHand(I)) return None;
    return Reloads.ReloadHand;
}

simulated function vector RenderedHandPosition(int I)
{
    local VRWeaponRuntime R;
    local VRReloadHandPose Drawn;
    Drawn = ReloadDrawnHand(I);
    if (Drawn != None) return Drawn.LastWrist;
    // Independent held hands belong to the exact item's presenter. The root
    // Arms bones are hidden while occupied and can retain an old neutral pose.
    // Wrist equipment and the watch must follow the visible hand, not that rig.
    if (RootBridge == None && HandInventory != None && HandInventory.Registry != None)
    {
        R = HandInventory.Registry.GetPrimary(I);
        if (R == None) R = HandInventory.Registry.GetSupport(I);
        if (R != None && R.Presenter != None && R.Presenter != self)
            return R.Presenter.RenderedHandPosition(I);
    }
    if (AttachedHandBones[I] != '' && AttachedHands[I] != None)
        return AttachedHands[I].GetBoneLocation(HandBone(I));
    return Arms.GetBoneLocation(HandBone(I));
}

simulated function quat RenderedHandRotation(int I)
{
    local VRWeaponRuntime R;
    local VRReloadHandPose Drawn;
    Drawn = ReloadDrawnHand(I);
    if (Drawn != None) return Drawn.LastWristQ;
    if (RootBridge == None && HandInventory != None && HandInventory.Registry != None)
    {
        R = HandInventory.Registry.GetPrimary(I);
        if (R == None) R = HandInventory.Registry.GetSupport(I);
        if (R != None && R.Presenter != None && R.Presenter != self)
            return R.Presenter.RenderedHandRotation(I);
    }
    if (AttachedHandBones[I] != '' && AttachedHands[I] != None)
        return AttachedHands[I].GetBoneQuaternion(HandBone(I));
    return Arms.GetBoneQuaternion(HandBone(I));
}

// Freeze the authored fingers once, then compose anchor -> component -> wrist.
// No world-space wrist target or per-frame skeletal solve participates in a
// grip. UE3 updates the child transform with the very same animated gun bone.
simulated function UpdateHandAttachment(KFWeapon W, int I, name BoneName, vector GripPosition, quat GripRotation)
{
    local KFSkeletalMeshComponent HandMesh;
    local AnimTree Template;
    local AnimNodeSequence Seq;
    local vector LocalWrist, RelativePosition;
    local quat LocalWristQ, RelativeQ;
    local int SourceHand;
    if (BoneName == '')
    {
        if (AttachedHandBones[I] != '')
        {
            AttachedHands[I].DetachFromAny();
            AttachedHands[I] = None;
            AttachedHandBones[I] = '';
            Arms.UnHideBoneByName(HandBone(I));
            bFreeHandPoseNeedsUpdate = true;
        }
        return;
    }
    if (AttachedHandBones[I] == BoneName && AttachedHands[I] != None
        && W.MySkelMesh.IsComponentAttached(AttachedHands[I], BoneName)) return;
    if (AttachedHands[I] != None) AttachedHands[I].DetachFromAny();
    HandMesh = new(self) class'KFSkeletalMeshComponent';
    HandMesh.bUseAsOccluder = false;
    HandMesh.SetSkeletalMesh(FloatingHandsMesh);
    HandMesh.SetMaterial(0, GetFloatingHandsMaterial());
    HandMesh.SetFOV(0);
    SourceHand = I == WeaponHand ? (WeaponProfiles[ActiveProfile].bPhysicalLowerHandlePrimary ? 0 : 1)
        : (WeaponProfiles[ActiveProfile].bPhysicalLowerHandlePrimary ? 1 : 0);
    if (PresentedItem != None && PresentedItem.PrimaryHand >= 0)
        SourceHand = I == PresentedItem.PrimaryHand
            ? (WeaponProfiles[ActiveProfile].bPhysicalLowerHandlePrimary ? 0 : 1)
            : (WeaponProfiles[ActiveProfile].bPhysicalLowerHandlePrimary ? 1 : 0);
    else if (PresentedItem != None)
        SourceHand = WeaponProfiles[ActiveProfile].bPhysicalLowerHandlePrimary ? 1 : 0;
    if (SourceHand == 0 && SupportPoseAnimSets.Length > 0)
        HandMesh.AnimSets = SupportPoseAnimSets;
    else HandMesh.AnimSets = W.MySkelMesh.AnimSets;
    HandMesh.bUpdateSkelWhenNotRendered = true;
    HandMesh.bTickAnimNodesWhenNotRendered = true;
    HandMesh.CastShadow = false;
    HandMesh.bCastDynamicShadow = false;
    HandMesh.SetLightingChannels(Arms.LightingChannels);
    UseWorldRendering(HandMesh);
    Template = new(self) class'AnimTree';
    Seq = new(Template) class'AnimNodeSequence';
    Seq.NodeName = 'VRBoundGrip';
    Seq.bNoNotifies = true;
    Template.Children[0].Anim = Seq;
    Template.Children[0].Weight = 1;
    HandMesh.SetAnimTreeTemplate(Template);
    Seq = AnimNodeSequence(HandMesh.FindAnimNode('VRBoundGrip'));
    Seq.SetAnim(WeaponProfiles[ActiveProfile].IdleAnimation);
    Seq.SetPosition(0, false);
    Seq.bPlaying = false;
    AttachComponent(HandMesh);
    HandMesh.ForceUpdate(false);
    if (PresentedItem != None)
    {
        if (!class'VRHandRolePose'.static.Apply(self, HandMesh, SourceHand, I))
        {
            HandMesh.DetachFromAny();
            AttachedHands[I] = None;
            AttachedHandBones[I] = '';
            Arms.UnHideBoneByName(HandBone(I));
            return;
        }
        GripRotation = class'VRHandRolePose'.static.RetargetWrist(self, SourceHand, I, GripRotation);
    }
    // HideBone indexes the evaluated SpaceBases array. A newly created mesh
    // has a valid skeleton but no pose array until attachment/update, so hiding
    // the unused hand before this point asserts in the native engine.
    HandMesh.HideBoneByName(HandBone(1 - I), PBO_None);
    HandMesh.ForceUpdate(false);
    // Space=1 excludes the mesh asset's Origin/RotOrigin, although rendering
    // includes them. Sample against this actor's attachment frame instead so
    // the fixed grip also cancels the imported hand mesh's 90-degree basis.
    LocalWrist = QuatRotateVector(QuatInvert(QuatFromRotator(Rotation)),
        HandMesh.GetBoneLocation(HandBone(I)) - Location);
    LocalWristQ = QuatProduct(QuatInvert(QuatFromRotator(Rotation)), HandMesh.GetBoneQuaternion(HandBone(I)));
    RelativeQ = QuatProduct(GripRotation, QuatInvert(LocalWristQ));
    RelativePosition = GripPosition - QuatRotateVector(RelativeQ, LocalWrist);
    CaptureBraceFrame(HandMesh, I, LocalWrist, RelativePosition, RelativeQ);
    HandMesh.DetachFromAny();
    W.MySkelMesh.AttachComponent(HandMesh, BoneName, RelativePosition, QuatToRotator(RelativeQ));
    AttachedHands[I] = HandMesh;
    AttachedHandBones[I] = BoneName;
    OtherHandRevealLogged[I] = 0;
    Arms.HideBoneByName(HandBone(I), PBO_None);
    `log("KF2VR_HANDS bone-attached weapon=" $ W.Class @ "hand=" $ I @ "bone=" $ BoneName);
}

// Records, in the same attachment frame as LocalWrist, the points the brace
// presentation turns about. A missing bone leaves the hand exactly as posed.
simulated function CaptureBraceFrame(KFSkeletalMeshComponent HandMesh, int I, vector LocalWrist,
    vector RelativePosition, quat RelativeQ)
{
    local name Pivot, Elbow;
    local quat InvActor;
    local string Side;
    BraceFrameReady[I] = 0;
    BraceApplied[I] = 0;
    BraceAngle[I] = 0;
    BraceTime[I] = -1;
    Side = I == 0 ? "Left" : "Right";
    Pivot = class'VRHandRolePose'.static.FingerBone(I, 2, 1);
    Elbow = name(Side $ "ForeArm_1stP");
    if (HandMesh.MatchRefBone(Elbow) < 0) Elbow = name(Side $ "ForeArmTwist1_1stP");
    if (HandMesh.MatchRefBone(Pivot) < 0 || HandMesh.MatchRefBone(Elbow) < 0) return;
    InvActor = QuatInvert(QuatFromRotator(Rotation));
    BraceWristLocal[I] = LocalWrist;
    BracePivotLocal[I] = QuatRotateVector(InvActor, HandMesh.GetBoneLocation(Pivot) - Location);
    BraceElbowLocal[I] = QuatRotateVector(InvActor, HandMesh.GetBoneLocation(Elbow) - Location);
    if (VSize(BraceElbowLocal[I] - BraceWristLocal[I]) < 1) return;
    BraceAttachPosition[I] = RelativePosition;
    BraceAttachRotation[I] = RelativeQ;
    BraceFrameReady[I] = 1;
}

// Pistol bracing only, and never in replays (their grip checks measure the
// authored contact). The swing is recomputed from the head every frame and
// smoothed, so recoil and head motion cannot make the glove jitter; a fresh
// attachment starts already swung.
simulated function PresentBracedSupport(KFWeapon W, int I)
{
    local KFSkeletalMeshComponent HandMesh;
    local quat BoneQ, FrameQ, OffsetQ;
    local vector Pivot, Forearm, ToHead, OffsetT;
    local float Target, DeltaTime;
    HandMesh = AttachedHands[I];
    if (HandMesh == None || AttachedHandBones[I] == '' || BraceFrameReady[I] == 0) return;
    // Presenters copy the root bridge's head position but not its tracking flag.
    if ((RootBridge != None ? RootBridge.NativeHeadTracked == 0 : NativeHeadTracked == 0)
        || !WeaponProfiles[ActiveProfile].bPistolBrace)
    {
        if (BraceApplied[I] != 0)
        {
            HandMesh.SetRotation(rot(0,0,0));
            HandMesh.SetTranslation(vect(0,0,0));
            BraceApplied[I] = 0;
        }
        BraceAngle[I] = 0;
        return;
    }
    BoneQ = W.MySkelMesh.GetBoneQuaternion(AttachedHandBones[I]);
    FrameQ = QuatProduct(BoneQ, BraceAttachRotation[I]);
    Pivot = W.MySkelMesh.GetBoneLocation(AttachedHandBones[I])
        + QuatRotateVector(BoneQ, BraceAttachPosition[I]) + QuatRotateVector(FrameQ, BracePivotLocal[I]);
    Forearm = QuatRotateVector(FrameQ, BraceElbowLocal[I] - BraceWristLocal[I]);
    ToHead = HeadPosition - Pivot;
    Target = class'VRPistolBracePresentation'.static.TargetCorrection(Forearm, ToHead,
        BraceFaceClearance, BraceMaxCorrection);
    if (BraceTime[I] < 0) BraceAngle[I] = Target;
    else
    {
        DeltaTime = FClamp(WorldInfo.RealTimeSeconds - BraceTime[I], 0, 0.1);
        BraceAngle[I] += (Target - BraceAngle[I]) * (1 - Exp(-DeltaTime / FMax(BraceSmoothTime, 0.01)));
    }
    BraceTime[I] = WorldInfo.RealTimeSeconds;
    if (BraceAngle[I] < 0.05)
    {
        if (BraceApplied[I] != 0)
        {
            HandMesh.SetRotation(rot(0,0,0));
            HandMesh.SetTranslation(vect(0,0,0));
            BraceApplied[I] = 0;
        }
        return;
    }
    class'VRPistolBracePresentation'.static.SolveOffset(FrameQ,
        class'VRPistolBracePresentation'.static.CorrectionAxis(Forearm, ToHead),
        BraceAngle[I], BracePivotLocal[I], OffsetQ, OffsetT);
    HandMesh.SetRotation(QuatToRotator(OffsetQ));
    HandMesh.SetTranslation(OffsetT);
    BraceApplied[I] = 1;
}

// Called after KFWeapon.SetPosition by the native script hook. The game has
// already processed visibility/attachment and its animation state normally.
simulated function PlaceWeapon()
{
    local KFWeapon W;
    local KFSkeletalMeshComponent M;
    local vector RootPos, HandPos, Target, Up, Forward, HitPos, HitNormal, SecondMuzzle;
    local quat RootQ, HandQ, DesiredQ, ActorQ, RelativeQ, PrimaryGripQ;
    local quat TwoHandAimQ, SmoothedCorrectionQ, BoreQ;
    local rotator DesiredRot, MuzzleRotation, ItemRecoil;
    local int I, SupportHand, AuthoredPrimaryHand, RiotShieldHand, ShotCount;
    local bool bOffhandGauntletVisible;
    local name RootBone;
    local float ReleaseElapsed, ReleaseAlpha, NowTime, KickImpulse, KickWeight, KickElapsed;

    // Native reads the scene-wide request from this root bridge, not the
    // per-item presenters. Publish it before independent placement returns.
    if (RootBridge == None)
        NativeKeepWorldDepth = int(NativeDepthSupported != 0);
    if (RootBridge == None && HandInventory != None)
    {
        HandInventory.PlaceAll();
        return;
    }
    if (Human == None) return;
    W = PresentedItem != None ? PresentedItem.Item : KFWeapon(Human.Weapon);
    ItemRecoil = PresentedItem != None ? PresentedItem.RecoilBuffer : PC.WeaponBufferRotation;
    if (!Supported(W) || NativeValidMask == 0) { HideWeaponLaser(); return; }
    // Native late placement refreshes these poses after pawn movement and
    // the head-pivot turn.
    Hands[0].Position = LeftPosition;
    Hands[1].Position = RightPosition;
    Hands[0].AimRotation = ControllerAimRotation(LeftRotation, W);
    Hands[1].AimRotation = ControllerAimRotation(RightRotation, W);
    ConfigureWeapon(W);
    if (ActiveProfile < 0) { HideWeaponLaser(); return; }
    AuthoredPrimaryHand = WeaponProfiles[ActiveProfile].bPhysicalLowerHandlePrimary ? 0 : 1;
    BoreQ = QuatFromRotator(WeaponProfiles[ActiveProfile].BoreRotation);
    if (WeaponProfiles[ActiveProfile].bPhysicalMelee) ItemRecoil = rot(0,0,0);
    EnforceWeaponMotion(W);
    if (ReloadMeshPresentation != None) ReloadMeshPresentation.Update(self, W);
    M = W.MySkelMesh;
    if (M == None || Arms == None || (NativeValidMask & (1 << WeaponHand)) == 0)
    {
        HideWeaponLaser();
        return;
    }
    // AttachWeaponTo may run after the first ConfigureWeapon call on a new
    // item. Reassert ownership whenever stock equip reattaches shared arms.
    if (Arms.ParentAnimComponent != None) Arms.SetParentAnimComponent(None);
    Arms.bTransformFromAnimParent = 0;
    if (RootBridge != None && Arms.Owner != RootBridge)
    {
        Arms.DetachFromAny();
        RootBridge.AttachComponent(Arms);
    }
    else if (RootBridge == None && Arms.Owner != self)
    {
        Arms.DetachFromAny();
        AttachComponent(Arms);
    }
    // FOV=0 gives the stock forward-lit weapon exactly the world's projection.
    // Native retains world depth for that pass, so nearby geometry occludes it.
    if (W.IsA('KFWeap_FlameBase') && FlameRendering != None) FlameRendering.Capture(W);
    if (M14Laser != None) M14Laser.Capture(W);
    if (M.FOV != 0) W.SetFOV(0);
    UpdateWorldRendering(W);
    if (M14Laser != None) M14Laser.Update(self);
    class'VRFlamePresentation'.static.Update(self, W);
    // SetPosition changes the actor before deferred component transforms run.
    // Read bones against that new transform, never a previous frame's matrix.
    M.ForceUpdate(true);
    RootBone = WeaponProfiles[ActiveProfile].RootBone;
    RootPos = M.GetBoneLocation(RootBone);
    RootQ = M.GetBoneQuaternion(RootBone);
    if (!bCalibrated) { HideWeaponLaser(); return; }
    DesiredRot = Hands[WeaponHand].AimRotation;
    SupportHand = 1 - WeaponHand;
    DesiredQ = QuatFromRotator(DesiredRot);
    // A melee weapon is held by the wrist, rather than aimed down a firearm
    // bore. Matching the calibrated primary wrist frame keeps axe handles in
    // the palm instead of inheriting a high/backward gun-aim pose. Melee guns
    // retain their bore-oriented firearm presentation.
    if (WeaponProfiles[ActiveProfile].bPhysicalMelee && !WeaponProfiles[ActiveProfile].bFirearm
        && FreeHandPose != None && FreeHandPose.bReady)
    {
        PrimaryGripQ = GripRotationInWeapon[AuthoredPrimaryHand];
        // Transfer the selected authored handle wrist to the opposite anatomy
        // before solving the root. Reusing the other hand's frame reverses the
        // shaft and raises its head behind the palm.
        if (WeaponHand != AuthoredPrimaryHand)
            PrimaryGripQ = class'VRHandRolePose'.static.RetargetWrist(self, AuthoredPrimaryHand, WeaponHand, PrimaryGripQ);
        DesiredQ = QuatProduct(FreeHandPose.WristRotation(WeaponHand,
            WeaponHand == 0 ? LeftRotation : RightRotation), QuatInvert(PrimaryGripQ));
        DesiredRot = QuatToRotator(DesiredQ);
    }
    // A pistol's support hand wraps the firing hand. Its short wrist baseline
    // cannot define a stable aim axis; primary orientation still owns the bore.
    if (bDisableSupportHandAim && WeaponProfiles[ActiveProfile].bFirearm)
    {
        // Apply the saved choice immediately, including a pending release
        // blend. Do not release the support role or discard braced recoil.
        bWasTwoHandedAim = false;
        bTwoHandReleaseSmoothing = false;
    }
    else if (!WeaponProfiles[ActiveProfile].bPistolBrace
        && Hands[SupportHand].SupportOwner == WeaponHand && !IsWeaponReadying(W) && !bReadyPoseSettling)
    {
        Forward = Normal(Hands[SupportHand].Position - Hands[WeaponHand].Position);
        if (VSizeSq(Hands[SupportHand].Position - Hands[WeaponHand].Position) > 100)
        {
            if (WeaponProfiles[ActiveProfile].bTwoHandBoreAim)
                Up = QuatRotateVector(DesiredQ, vect(1,0,0));
            else
                Up = QuatRotateVector(DesiredQ, QuatRotateVector(QuatInvert(BoreQ), Normal(SupportGrip - PrimaryGrip)));
            TwoHandAimQ = QuatFindBetween(Up, Forward);
            // Support-hand engage Slerp over 0.025 s (AS2
            // switchToTwoHandedLerpTimeInSeconds), from whatever correction
            // is showing, so a regrab during the release blend cannot jump.
            if (!bWasTwoHandedAim)
            {
                TwoHandEngageFromQ = QuatFromRotator(rot(0,0,0));
                ReleaseElapsed = WorldInfo.RealTimeSeconds - TwoHandReleaseTime;
                if (bTwoHandReleaseSmoothing && ReleaseElapsed >= 0.0 && ReleaseElapsed < 0.10)
                    TwoHandEngageFromQ = QuatSlerp(TwoHandEngageFromQ, LastTwoHandCorrectionQ, 1.0 - ReleaseElapsed / 0.10, true);
                bTwoHandReleaseSmoothing = false;
                TwoHandEngageTime = WorldInfo.RealTimeSeconds;
            }
            ReleaseElapsed = WorldInfo.RealTimeSeconds - TwoHandEngageTime;
            if (ReleaseElapsed >= 0.0 && ReleaseElapsed < 0.025)
                TwoHandAimQ = QuatSlerp(TwoHandEngageFromQ, TwoHandAimQ, ReleaseElapsed / 0.025, true);
            DesiredQ = QuatProduct(TwoHandAimQ, DesiredQ);
            DesiredRot = QuatToRotator(DesiredQ);
            LastTwoHandCorrectionQ = TwoHandAimQ;
            bWasTwoHandedAim = true;
        }
    }
    else
    {
        // Support-hand release Slerp: smooth two-hand grip break over ~0.10s (AS2 feel).
        if (bWasTwoHandedAim)
        {
            bWasTwoHandedAim = false;
            bTwoHandReleaseSmoothing = true;
            TwoHandReleaseTime = WorldInfo.RealTimeSeconds;
        }
        if (bTwoHandReleaseSmoothing)
        {
            ReleaseElapsed = WorldInfo.RealTimeSeconds - TwoHandReleaseTime;
            if (ReleaseElapsed >= 0.0 && ReleaseElapsed < 0.10)
            {
                ReleaseAlpha = 1.0 - (ReleaseElapsed / 0.10);
                SmoothedCorrectionQ = QuatSlerp(QuatFromRotator(rot(0,0,0)), LastTwoHandCorrectionQ, ReleaseAlpha, true);
                DesiredQ = QuatProduct(SmoothedCorrectionQ, DesiredQ);
                DesiredRot = QuatToRotator(DesiredQ);
            }
            else
            {
                bTwoHandReleaseSmoothing = false;
            }
        }
    }
    DesiredRot += ItemRecoil;
    DesiredQ = QuatFromRotator(DesiredRot);

    // Hand-space recoil kick (AS2 feel). The shot is the trigger: the stock
    // recoil buffer ramps toward each shot's pitch over RecoilRate (45-90 ms),
    // so a per-frame pitch delta scaled with frame time and never crossed the
    // old 80-unit gate on light guns at 90 fps. Each new FlashCount adds one
    // impulse sized from the gun's stock recoil on the same log curve as the
    // shot haptics (MP7 about 0.8 cm, 9mm 1.9, Deagle 2.9, M99 4.0), halved
    // while braced, applied over 45 ms and recovered over 0.15-0.6 s so a
    // heavy gun settles slower than a pistol. The tracked hand never moves.
    NowTime = WorldInfo.RealTimeSeconds;
    ShotCount = PresentedItem != None ? int(PresentedItem.NativeFlashCount) : int(Human.FlashCount);
    if (ShotCount != LastKickShotCount)
    {
        if (LastKickShotCount >= 0 && ShotCount != 0 && WeaponProfiles[ActiveProfile].bFirearm)
        {
            KickWeight = FClamp(float(W.minRecoilPitch + W.maxRecoilPitch) * 0.5, 50.0, 1200.0);
            KickWeight = Loge(KickWeight / 50.0) / Loge(24.0);
            KickImpulse = 0.8 + 3.2 * KickWeight;
            if (Hands[SupportHand].SupportOwner == WeaponHand) KickImpulse *= 0.5;
            RecoilKickFrom = RecoilKick;
            RecoilKickPeak = FMin(RecoilKick + KickImpulse, 5.0);
            RecoilKickStart = NowTime;
            RecoilKickRecover = 0.15 + 0.45 * KickWeight;
        }
        LastKickShotCount = ShotCount;
    }
    if (RecoilKickPeak > 0.0)
    {
        KickElapsed = FMax(NowTime - RecoilKickStart, 0.0);
        if (KickElapsed < 0.045) RecoilKick = Lerp(RecoilKickFrom, RecoilKickPeak, KickElapsed / 0.045);
        else RecoilKick = RecoilKickPeak * Exp(-(KickElapsed - 0.045) * 2.3 / FMax(RecoilKickRecover, 0.05));
        if (RecoilKick < 0.02) { RecoilKick = 0.0; RecoilKickPeak = 0.0; }
    }
    else RecoilKick = 0.0;

    // Tracking, bracing and recoil above describe the bore. Solve the authored
    // root frame before applying action motion and anchoring its grip.
    DesiredQ = QuatProduct(DesiredQ, QuatInvert(BoreQ));

    // The first Idle/fire pose may still blend from the outgoing ready pose.
    // Do not briefly reintroduce that pose's large arm offset after the timer.
    // An orphaned cache reports a settled blend because nothing advances it.
    // That is not evidence the incoming pose has finished arriving.
    if (IsWeaponReadying(W)) bReadyPoseSettling = true;
    else if (W.WeaponAnimSeqNode != None && W.WeaponAnimSeqNode.BlendTimeToGo <= 0
        && !HasStaleWeaponAnimNode(W)) bReadyPoseSettling = false;
    // Firing can interrupt sprint before its outro returns to Idle. The new
    // action still contains cached sprint bones during its incoming tween.
    if (IsPassiveWeaponAnimation(W) && !IsIdleWeaponAnimation(W)) bSprintPoseSettling = true;
    else if (W.WeaponAnimSeqNode != None && W.WeaponAnimSeqNode.BlendTimeToGo <= 0) bSprintPoseSettling = false;
    // Ready/equip and passive idle/sprint never displace the tracked gun.
    // Deliberate actions retain authored rotation and articulated part motion.
    // Discard root translation: desktop reload/fire choreography must not pull
    // the primary grip away from the tracked controller. Sample component space
    // so the animation stays independent of tracking and locomotion.
    // A physical reload is the exception: the hands turn the gun, so the
    // stock reload choreography does not.
    if (!WeaponProfiles[ActiveProfile].bPhysicalMelee && !IsWeaponReadying(W) && !bReadyPoseSettling
        && !bSprintPoseSettling && !IsPassiveWeaponAnimation(W) && !IsSelfHealAnimation(W)
        && !InteractiveReloadHolds(W))
    {
        DesiredQ = QuatProduct(DesiredQ, QuatProduct(QuatInvert(IdleRootRotation), M.GetBoneQuaternion(RootBone, 1)));
    }
    // Anchor AFTER all rotations, including recoil and action animation, so
    // they pivot around the held grip instead of swinging that grip away.
    Target = Hands[WeaponHand].Position - QuatRotateVector(DesiredQ, PrimaryGrip);
    if (RecoilKick > 0.0)
    {
        Target -= QuatRotateVector(QuatProduct(DesiredQ, BoreQ), vect(1,0,0)) * RecoilKick;
    }
    // Stock adjusted aim adds the recoil buffer. Include the visible animation
    // in its input while leaving that stock recoil addition exactly once.
    FireRotation = QuatToRotator(QuatProduct(DesiredQ, BoreQ)) - ItemRecoil;
    if (bSightLineConvergence && WeaponProfiles[ActiveProfile].bFirearm)
    {
        FireRotation.Pitch += 24;
    }
    ActorQ = QuatFromRotator(W.Rotation);
    RelativeQ = QuatProduct(QuatInvert(ActorQ), RootQ);
    HandPos = QuatRotateVector(QuatInvert(ActorQ), RootPos - W.Location);
    ActorQ = QuatProduct(DesiredQ, QuatInvert(RelativeQ));
    W.SetRotation(QuatToRotator(ActorQ));
    // Position with the quantized rotation the actor actually uses.
    W.SetLocation(Target - QuatRotateVector(QuatFromRotator(W.Rotation), HandPos));
    M.ForceUpdate(true);
    // The Riot Shield, Bone Crusher shield and left gauntlets ride the tracked
    // off hand, not the right hand's animation.
    if (RiotShield != None)
    {
        RiotShieldHand = SupportHand;
        if (WeaponProfiles[ActiveProfile].bPhysicalDualGauntlets)
        {
            // LW_Weapon is a real second held object. Hide it whenever that
            // controller is explicitly opened or has another interaction; a
            // suspended control alone leaves its stock gauntlet floating.
            bOffhandGauntletVisible = VRWeaponPresenter(self) != None
                && VRWeaponPresenter(self).bOffhandGauntletEnabled && PresentedItem != None
                && RootBridge != None && RootBridge.HandInventory != None
                && RootBridge.HandInventory.CanStrikeGauntlet(PresentedItem, SupportHand);
            if (!bOffhandGauntletVisible)
            {
                RiotShield.Suspend();
                M.HideBoneByName('LW_Weapon', PBO_None);
            }
            else
            {
                M.UnHideBoneByName('LW_Weapon');
                RiotShield.Update(self, W, (NativeValidMask & (1 << RiotShieldHand)) != 0 ? RiotShieldHand : -1);
            }
        }
        else RiotShield.Update(self, W, (RiotShieldHand >= 0 && (NativeValidMask & (1 << RiotShieldHand)) != 0) ? RiotShieldHand : -1);
    }
    FireLocation = Target + QuatRotateVector(DesiredQ, vect(20,0,6));
    MuzzleRotation = QuatToRotator(M.GetBoneQuaternion(RootBone));
    if (WeaponProfiles[ActiveProfile].MuzzleSocket != '')
    {
        if (!M.GetSocketWorldLocationAndRotation(WeaponProfiles[ActiveProfile].MuzzleSocket, FireLocation, MuzzleRotation))
        {
            NativeWeaponReady = 0;
            NativeControlsEnabled = 0;
            ReleaseControls();
            HideWeaponLaser();
            return;
        }
        if (WeaponProfiles[ActiveProfile].SecondaryMuzzleSocket != '')
        {
            if (!M.GetSocketWorldLocationAndRotation(WeaponProfiles[ActiveProfile].SecondaryMuzzleSocket, SecondMuzzle))
            {
                NativeWeaponReady = 0;
                NativeControlsEnabled = 0;
                ReleaseControls();
                HideWeaponLaser();
                return;
            }
            // Stock shotgun pellets share one physical fire origin. Use the
            // center of the actual two muzzles for both pellets and the guide.
            FireLocation = (FireLocation + SecondMuzzle) * 0.5;
        }
    }
    // A transient socket read can recover on a later component update.
    NativeWeaponReady = 1;
    PlacedMuzzleDistance = VSize(FireLocation - Target);
    PlacedRootError = VSize(M.GetBoneLocation(RootBone) - Target);
    // Presentation follows the socket's actual bore, including a hunting
    // shotgun's opening barrels during reload, independently of stock aim.
    // Keep shot-origin wall safety separate from this literal optical ray.
    LaserMuzzleLocation = FireLocation;
    LaserMuzzleRotation = MuzzleRotation;
    if (WeaponProfiles[ActiveProfile].LaserSocket != '')
        M.GetSocketWorldLocationAndRotation(WeaponProfiles[ActiveProfile].LaserSocket, LaserMuzzleLocation, LaserMuzzleRotation);
    // The shot leaves along DesiredQ; stock adjusted aim adds back exactly the
    // recoil FireRotation subtracted. A muzzle socket parented to a moving part
    // does not follow that axis: the M79's cooked MuzzleFlash hangs off
    // RW_Barrel, so a gun that breaks open after every single shot would aim
    // its beam down the hinging barrel while the grenade leaves along the
    // receiver. Keep the socket's origin and take the bore the shot uses.
    if (WeaponProfiles[ActiveProfile].bLaserUsesBoreRotation)
        LaserMuzzleRotation = QuatToRotator(DesiredQ);
    // A muzzle pushed through a wall cannot start a shot on its far side.
    if (Trace(HitPos, HitNormal, FireLocation, HeadPosition, false) != None)
        FireLocation = HitPos + HitNormal * 2;
    if (AF2011Barrels != None && !AF2011Barrels.Update(self, FireLocation))
    {
        NativeWeaponReady = 0;
        NativeControlsEnabled = 0;
        ReleaseControls();
        HideWeaponLaser();
        return;
    }
    Hands[WeaponHand].FirePosition = FireLocation;
    Hands[WeaponHand].FireRotation = FireRotation;
    UpdateWeaponLaser(W);
    if (M14Scope != None) M14Scope.Update();
    if (VRTrackedPresentation(W) != None) VRTrackedPresentation(W).UpdateTrackedPresentation(self);
    // The hand component's actor follows the torso; targets come from the
    // original grip. The support target follows its animated gun part rather
    // than inheriting reload's untracked arm choreography.
    SetLocation(Human.Location + vect(0,0,1) * Human.BaseEyeHeight);
    SetRotation(BodyRotation);
    // Keep the fill around the held receiver instead of lighting a large
    // head-centered volume. Nearby geometry can receive a little spill;
    // deferred lighting has no per-weapon channel in this shipped renderer.
    HandFillLight.SetTranslation((Hands[WeaponHand].Position + vect(0,0,15) - Location) << Rotation);
    HandFillLight.ForceUpdate(true);
    for (I = 0; I < 2; ++I)
    {
        // Another presenter or the root neutral rig owns the other hand.
        if (PresentedItem != None && I != WeaponHand && Hands[I].SupportOwner != WeaponHand) continue;
        HandPos = Hands[I].Position;
        HandQ = FreeHandPose.WristRotation(I, I == 0 ? LeftRotation : RightRotation);
        if (I == WeaponHand)
        {
            if (PresentedItem != None && PresentedItem.PrimaryHand < 0)
            {
                GetSupportGripWorld(W, HandPos, HandQ);
                UpdateHandAttachment(W, I, WeaponProfiles[ActiveProfile].SupportBone, SupportGripOffset, SupportGripRotation);
            }
            else
            {
                RelativeQ = GripRotationInWeapon[AuthoredPrimaryHand];
                if (I != AuthoredPrimaryHand)
                    RelativeQ = class'VRHandRolePose'.static.RetargetWrist(self,
                        AuthoredPrimaryHand, I, RelativeQ);
                HandQ = QuatProduct(M.GetBoneQuaternion(RootBone), RelativeQ);
                HandPos = M.GetBoneLocation(RootBone) + QuatRotateVector(M.GetBoneQuaternion(RootBone), PrimaryGrip);
                UpdateHandAttachment(W, I, RootBone, PrimaryGrip, GripRotationInWeapon[AuthoredPrimaryHand]);
            }
        }
        else if (Hands[I].SupportOwner == WeaponHand && !IsWeaponReadying(W) && !bReadyPoseSettling)
        {
            // ForceUpdate above has already moved the component: sample its
            // current world support pose only once (pump or hinged barrels).
            GetSupportGripWorld(W, HandPos, HandQ);
            UpdateHandAttachment(W, I, WeaponProfiles[ActiveProfile].SupportBone, SupportGripOffset, SupportGripRotation);
            PresentBracedSupport(W, I);
        }
        else UpdateHandAttachment(W, I, '', vect(0,0,0), HandQ);
        if (WristIK[I] != None)
        {
            WristIK[I].BoneTranslation = HandPos;
            WristIK[I].BoneRotation = QuatToRotator(HandQ);
        }
    }
    // A just-detached support hand must evaluate its new controller target
    // before becoming visible; transform updates alone retain its old bones.
    if (bFreeHandPoseNeedsUpdate)
    {
        Arms.ForceSkelUpdate();
        bFreeHandPoseNeedsUpdate = false;
    }
    Arms.ForceUpdate(true);
    // Refresh attachments through their parent, never ForceUpdate a child
    // attached to a bone (that API requires direct actor ownership).
    M.ForceUpdate(true);
    if (++PoseCount <= 3 || PoseCount % 300 == 0)
        `log("KF2VR_HANDS placed count=" $ PoseCount @ "weapon=" $ W.Class @ "aim=" $ FireRotation
            @ "root=" $ Target @ "hand=" $ Hands[WeaponHand].Position @ "support=" $ Hands[SupportHand].SupportOwner
            @ "rootError=" $ PlacedRootError @ "muzzleDistance=" $ PlacedMuzzleDistance @ "fire=" $ FireLocation);
}

simulated function UseWorldRendering(PrimitiveComponent C)
{
    local KFSkeletalMeshComponent Skel;
    local KFParticleSystemComponent Particle;

    if (C == None) return;
    if (C.DepthPriorityGroup != SDPG_World) C.SetDepthPriorityGroup(SDPG_World);
    if (C.bUseViewOwnerDepthPriorityGroup) C.SetViewOwnerDepthPriorityGroup(false, SDPG_World);
    Skel = KFSkeletalMeshComponent(C);
    if (Skel != None && Skel.FOV != 0) Skel.SetFOV(0);
    Particle = KFParticleSystemComponent(C);
    if (Particle != None)
    {
        if (Particle.FOV != 0) Particle.SetFOV(0);
        // Stock shell ejection can explicitly disable depth testing.
        Particle.bDepthTestEnabled = true;
    }
}

simulated function UpdateWorldRendering(KFWeapon W)
{
    local PrimitiveComponent C;
    local int I, Bone;
    local LightingChannelContainer Channels;

    NativeKeepWorldDepth = int(NativeDepthSupported != 0);
    // MeshComponent defaults to an occluder. KF2 draws foreground occluders
    // into the world prepass before issuing world visibility queries; the two
    // stereo eyes currently share those query histories. A near-face tracked
    // gun must not cull whole world primitives behind its other-eye silhouette.
    // This only removes its depth-only prepass: the visible forward draw still
    // tests and writes geometric depth, including preserved world/hand depth.
    if (W.MySkelMesh.bUseAsOccluder)
    {
        W.MySkelMesh.bUseAsOccluder = false;
        W.MySkelMesh.ForceUpdate(false);
    }
    foreach W.AllOwnedComponents(class'PrimitiveComponent', C)
        if (C != W.MySkelMesh) UseWorldRendering(C);
    if (NativeDepthSupported != 0)
    {
        if (W.MySkelMesh.DepthPriorityGroup != SDPG_Foreground) W.MySkelMesh.SetDepthPriorityGroup(SDPG_Foreground);
        if (W.MySkelMesh.bUseViewOwnerDepthPriorityGroup) W.MySkelMesh.SetViewOwnerDepthPriorityGroup(false, SDPG_Foreground);
    }
    else UseWorldRendering(W.MySkelMesh);
    UseWorldRendering(Arms);
    // Stock foreground weapons inherit the old arms' shadow parent. Their
    // independent world transforms need their own lighting and bounds.
    if (W.MySkelMesh.ShadowParent != None) W.MySkelMesh.SetShadowParent(None);
    if (W.MySkelMesh.bAllowPerObjectShadows || W.MySkelMesh.CastShadow)
    {
        // KF2's foreground per-object shadow path does not supply world-pass
        // illumination for this late-placed mesh. Use normal dynamic lighting.
        W.MySkelMesh.SetPerObjectShadows(false);
        W.MySkelMesh.CastShadow = false;
        W.MySkelMesh.bCastDynamicShadow = false;
        W.MySkelMesh.ForceUpdate(false);
    }
    Channels = Human.PawnLightingChannel;
    Channels.Dynamic = true;
    // DeferredLightingCommon packs only Indoor/Outdoor into the per-pixel
    // light mask. A private Unnamed channel never reaches world-pass pixels.
    if (!W.MySkelMesh.LightingChannels.Dynamic || W.MySkelMesh.LightingChannels.Indoor != Channels.Indoor
        || W.MySkelMesh.LightingChannels.Outdoor != Channels.Outdoor) W.MySkelMesh.SetLightingChannels(Channels);
    if (!Arms.LightingChannels.Dynamic || Arms.LightingChannels.Indoor != Channels.Indoor
        || Arms.LightingChannels.Outdoor != Channels.Outdoor) Arms.SetLightingChannels(Channels);
    for (I = 0; I < 2; ++I)
    {
        if (AttachedHands[I] == None) continue;
        // Each bound grip is a two-hand mesh posed by the gun's own idle, so
        // its unused hand sits on the gun. A reattach can restore that hand;
        // a left-held pistol then shows both hands bracing it.
        Bone = AttachedHands[I].MatchRefBone(HandBone(1 - I));
        if (Bone != INDEX_NONE && AttachedHands[I].bAttached && Bone < AttachedHands[I].BoneVisibilityStates.Length
            && !AttachedHands[I].IsBoneHidden(Bone))
        {
            AttachedHands[I].HideBone(Bone, PBO_None);
            if (OtherHandRevealLogged[I] == 0)
            {
                OtherHandRevealLogged[I] = 1;
                `log("KF2VR_HANDS other-hand-rehidden weapon=" $ W.Class @ "hand=" $ I @ "bone=" $ AttachedHandBones[I]);
            }
        }
        UseWorldRendering(AttachedHands[I]);
        AttachedHands[I].SetFOV(0);
        if (!AttachedHands[I].LightingChannels.Dynamic || AttachedHands[I].LightingChannels.Indoor != Channels.Indoor
            || AttachedHands[I].LightingChannels.Outdoor != Channels.Outdoor) AttachedHands[I].SetLightingChannels(Channels);
    }
    // Arms are detached from the gun for independent IK. Stock W.SetFOV no
    // longer updates them, and equipped sleeves can have their own override.
    for (I = 0; I < `MAX_COSMETIC_ATTACHMENTS; ++I)
    {
        UseWorldRendering(Human.FirstPersonAttachments[I]);
        // Cosmetic sleeves are separate meshes and must not leave detached
        // forearms behind. Character-specific floating gloves can be added
        // later using the same wrist rig and per-character mesh/materials.
        if (Human.FirstPersonAttachments[I] != None) Human.FirstPersonAttachments[I].SetHidden(true);
    }
}

simulated function HideWeaponLaser()
{
    if (M14Scope != None) M14Scope.Suspend();
    if (WeaponLaser != None) WeaponLaser.HideLaser();
}

simulated function UpdateWeaponLaser(KFWeapon W)
{
    local rotator CenterAim;

    if (!bWeaponLasers || !bNativeEnabled || !bCalibrated || NativeControlsEnabled == 0
        || Human.Health <= 0 || (PresentedItem == None && W != Human.Weapon) || W.MySkelMesh.HiddenGame
        || VRTrackedWeapon(W) != None || !UsesFirearmProfile(W) || W.IsInState('Inactive')
        || W.IsInState('WeaponPuttingDown') || W.IsInState('WeaponEquipping')
        || (NativeValidMask & (1 << WeaponHand)) == 0)
    {
        // Optics evaluate their own tracking/menu/pose gates after this call.
        // Disabling the optional guide must not reset scope eye-relief hysteresis.
        if (WeaponLaser != None) WeaponLaser.HideLaser();
        return;
    }
    if (WeaponLaser == None)
    {
        WeaponLaser = Spawn(class'VRWeaponLaser', self);
        if (WeaponLaser == None) return;
        `log("KF2VR_LASER enabled=true beam=" $ WeaponLaser.Beam.StaticMesh
            @ "dot=" $ WeaponLaser.Dot.StaticMesh @ "depth=world range=weapon-capped-20000");
    }
    // A laser is an optical barrel ray. Never request adjusted aim, magnetism,
    // target adhesion, or spread from the weapon/controller firing code.
    CenterAim = LaserMuzzleRotation;
    WeaponLaser.UpdateAim(W, LaserMuzzleLocation, CenterAim);
}

simulated event Destroyed()
{
    EndMenuRender();
    if (InventoryFocus != None) { InventoryFocus.Shutdown(); InventoryFocus = None; }
    if (HandInventory != None) { HandInventory.Shutdown(); HandInventory = None; }
    if (HeldInventory != None) { HeldInventory.Shutdown(); HeldInventory = None; }
    if (SpatialHUD != None) { SpatialHUD.Destroy(); SpatialHUD = None; }
    ClearHandAttachments();
    RestoreWeaponMotion();
    if (ActiveWeapon != None && ActiveProfile >= 0 && ActiveWeapon.MySkelMesh != None)
        ActiveWeapon.MySkelMesh.bForceUpdateAttachmentsInTick = bOriginalForceAttachmentsInTick;
    RestoreWeaponRendering();
    RestoreFreeHandsOccluder();
    if (GripPoseMesh != None) { GripPoseMesh.DetachFromAny(); GripPoseMesh = None; }
    if (WeaponLaser != None) { WeaponLaser.Destroy(); WeaponLaser = None; }
    Super.Destroyed();
}

simulated function RestoreFreeHandsOccluder()
{
    // Only the root that converted the pawn's arms owns this snapshot. Item
    // presenters share Arms and must not restore it when one weapon is stowed.
    if (OriginalFreeHandsOccluderMesh == None) return;
    if (OriginalFreeHandsOccluderMesh.bUseAsOccluder != bOriginalFreeHandsOccluder)
    {
        OriginalFreeHandsOccluderMesh.bUseAsOccluder = bOriginalFreeHandsOccluder;
        if (OriginalFreeHandsOccluderMesh.bAttached && OriginalFreeHandsOccluderMesh.Owner != None)
            OriginalFreeHandsOccluderMesh.ForceUpdate(false);
    }
    OriginalFreeHandsOccluderMesh = None;
}

simulated function UpdateHands()
{
    local int I;
    local bool Grip, Trigger;
    local vector Zone;
    local quat ZoneRotation;
    local KFWeapon W;
    Hands[0].Position = LeftPosition;
    Hands[1].Position = RightPosition;
    W = KFWeapon(Human.Weapon);
    Hands[0].AimRotation = ControllerAimRotation(LeftRotation, W);
    Hands[1].AimRotation = ControllerAimRotation(RightRotation, W);
    ConfigureWeapon(W);
    NativeControlsEnabled = int(Supported(W) && ActiveProfile >= 0);
    if (NativeMenuInputBlocked != 0)
    {
        NativeControlsEnabled = 0;
        ReleaseControls();
        PlaceWeapon();
        return;
    }
    // Stock positioning and component transforms may have advanced since the
    // previous draw. Place against the current controller before testing the
    // grab zone, then place again below if support ownership changes.
    PlaceWeapon();
    if (bCarrySupportGrip)
    {
        if ((NativeGripMask & 3) != 3 || (NativeGripActiveMask & 3) != 3 || (NativeValidMask & 3) != 3)
            bCarrySupportGrip = false;
        else if (bCalibrated && NativeWeaponReady != 0 && ActiveProfile >= 0
            && WeaponProfiles[ActiveProfile].SupportBone != '')
        {
            Hands[1 - WeaponHand].SupportOwner = WeaponHand;
            bCarrySupportGrip = false;
        }
    }
    for (I = 0; I < 2; ++I)
    {
        Grip = (NativeGripMask & (1 << I)) != 0;
        Trigger = (NativeTriggerMask & (1 << I)) != 0;
        if ((NativeValidMask & (1 << I)) == 0)
        {
            Hands[I].SupportOwner = -1;
            Hands[I].bGripArmed = false;
            Hands[I].bTriggerArmed = false;
            if (Hands[I].Item != None)
            {
                Hands[I].Item.StopFire(0);
                Hands[I].Item.StopFire(1);
                class'VRBurstFireControl'.static.CancelAction(Hands[I].Item);
                class'VRFlamePresentation'.static.CancelAction(Hands[I].Item);
                if (Hands[I].Item.IsA('KFWeap_MeleeBase')) Hands[I].Item.StopFire(5);
            }
            Hands[I].bTrigger = false;
            continue;
        }
        if ((NativeGripActiveMask & (1 << I)) == 0)
        {
            Hands[I].bGripArmed = false;
            Grip = false;
        }
        else if (!Grip) Hands[I].bGripArmed = true;
        if ((NativeTriggerActiveMask & (1 << I)) == 0)
        {
            Hands[I].bTriggerArmed = false;
            Trigger = false;
            class'VRBurstFireControl'.static.CancelAction(Hands[I].Item);
            class'VRFlamePresentation'.static.CancelAction(Hands[I].Item);
        }
        else if (!Trigger && (I == 0 ? LeftTriggerValue : RightTriggerValue) <= 0.1)
            Hands[I].bTriggerArmed = true;
        if (!Grip) Hands[I].SupportOwner = -1;
        if (Grip && !Hands[I].bGrip && Hands[I].bGripArmed && I != WeaponHand && bCalibrated
            && GetSupportGripWorld(W, Zone, ZoneRotation))
        {
            if (VSize(Hands[I].Position - Zone) < 18)
                Hands[I].SupportOwner = WeaponHand;
        }
        Hands[I].bGrip = Grip;
    }
    NativeHudSuppressMask = (Hands[0].SupportOwner >= 0 ? 1 : 0) | (Hands[1].SupportOwner >= 0 ? 2 : 0);
    PlaceWeapon();
    if (!Supported(W) || !bCalibrated || NativeWeaponReady == 0)
    {
        // An item whose mesh cannot calibrate (Source meshes carry no left
        // hand bone) must not strand the player: Y still selects the next item.
        if ((NativeButtonMask & NativeButtonActiveMask & 2) != 0 && (PreviousButtons & 2) == 0) SelectNextItem();
        PreviousButtons = (PreviousButtons & ~2) | (NativeButtonMask & NativeButtonActiveMask & 2);
        return;
    }
    if ((NativeValidMask & (1 << WeaponHand)) == 0)
    {
        ReleaseControls();
        return;
    }
    NativeButtonMask = FilterWeaponButtons(NativeButtonMask, NativeButtonActiveMask);
    if (VRTrackedWeapon(W) != None)
    {
        VRTrackedWeapon(W).UpdateTrackedInput(self);
        return;
    }
    if (W.IsA('KFWeap_MeleeBase'))
    {
        class'VRMeleeControls'.static.Update(self, W);
        return;
    }
    I = WeaponHand;
    Trigger = (NativeTriggerMask & (1 << I)) != 0 && Hands[I].bTriggerArmed && (NativeValidMask & (1 << I)) != 0;
    if (Trigger != Hands[I].bTrigger)
    {
        if (Trigger)
        {
            if (W.IsA('KFWeap_Healer_Syringe') && VSize(Hands[I].Position - (HeadPosition - vect(0,0,35))) < 32)
                W.StartFire(1);
            else if (WeaponProfiles[ActiveProfile].bGripAltFire && Hands[I].bGrip && Hands[I].bGripArmed)
                W.StartFire(1);
            else W.StartFire(0);
        }
        else { W.StopFire(0); W.StopFire(1); }
        Hands[I].bTrigger = Trigger;
    }
    // Both lower face buttons reload the currently equipped prototype gun.
    // Keep their physical bits separate for per-hand ownership as inventory
    // support expands. Left trigger uses the stock interact path exclusively.
    if ((NativeButtonMask & 9) != 0 && (PreviousButtons & 9) == 0)
    {
        W.StartFire(2);
    }
    if ((NativeButtonMask & 9) == 0 && (PreviousButtons & 9) != 0) W.StopFire(2);
    if ((NativeButtonMask & 2) != 0 && (PreviousButtons & 2) == 0) SelectNextItem();
    if ((NativeButtonMask & 4) != 0 && (PreviousButtons & 4) == 0) Human.ToggleEquipment();
    PreviousButtons = NativeButtonMask;
}

// Native calls this when a local melee item plays its stock block or parry
// effects (damage and grabs, solo or as a network client). The stock sound and
// particle remain; this adds the one cue a VR player reliably notices.
simulated function NotifyMeleeDefense(KFWeapon W, int Parried)
{
    local VRWeaponRuntime R;
    local int Hand, Mask;
    Hand = -1;
    if (W == None) return;
    if (HeldInventory != None) R = HeldInventory.FindItem(W);
    if (R != None) Hand = R.PrimaryHand;
    else if (W == ActiveWeapon) Hand = WeaponHand;
    if (Hand < 0 || Hand > 1) return;
    Mask = 1 << Hand;
    if (Hands[1 - Hand].SupportOwner == Hand) Mask = 3;
    class'VRMeleeControls'.static.Pulse(self, Mask, Parried != 0 ? 1.0 : 0.65, Parried != 0 ? 0.12 : 0.05);
    `log("KF2VR_MELEE_DEFENSE kind=" $ (Parried != 0 ? "parry" : "block") @ "weapon=" $ W.Class @ "hand=" $ Hand);
}

simulated function ReleaseControls()
{
    local int I;
    if (InventoryFocus != None) InventoryFocus.Shutdown();
    if (PhysicalMelee != None) PhysicalMelee.Cancel();
    if (PhysicalBash != None) PhysicalBash.Cancel();
    if (RootBridge == None && HandInventory != None) HandInventory.CancelInput();
    if (VRTrackedWeapon(ActiveWeapon) != None) VRTrackedWeapon(ActiveWeapon).CancelTrackedInput();
    bCarrySupportGrip = false;
    ArmedButtons = 0;
    LatchedXAction = 0;
    for (I = 0; I < 2; ++I)
    {
        Hands[I].SupportOwner = -1;
        Hands[I].bGripArmed = false;
        Hands[I].bTriggerArmed = false;
        Hands[I].bGrip = false;
        Hands[I].bTrigger = false;
        if (Hands[I].Item != None)
        {
            Hands[I].Item.StopFire(0);
            Hands[I].Item.StopFire(1);
            Hands[I].Item.StopFire(2);
            class'VRBurstFireControl'.static.CancelAction(Hands[I].Item);
            class'VRFlamePresentation'.static.CancelAction(Hands[I].Item);
            if (Hands[I].Item.IsA('KFWeap_MeleeBase')) Hands[I].Item.StopFire(5);
            Hands[I].Item.SetIronSights(false);
        }
    }
    PreviousButtons = NativeButtonMask;
}

simulated function SelectNextItem()
{
    local Inventory Item;
    local int Offset, NextProfile, CurrentProfile;
    if (Human == None || Human.InvManager == None || WeaponProfiles.Length == 0) return;
    // A held item still awaiting content has no ActiveWeapon; continue from it
    // rather than restarting the profile order.
    CurrentProfile = FindWeaponProfile(ActiveWeapon != None ? ActiveWeapon : KFWeapon(Human.Weapon));
    // Skip missing/sold items and wrap the shared profile order.
    for (Offset = 1; Offset <= WeaponProfiles.Length; ++Offset)
    {
        NextProfile = (CurrentProfile + Offset) % WeaponProfiles.Length;
        // The same exact-class boundary as ownership: cycling must not stop on
        // an unaudited subclass that merely inherits this profile's name.
        for (Item = Human.InvManager.InventoryChain; Item != None; Item = Item.Inventory)
            if (KFWeapon(Item) != None && FindWeaponProfile(KFWeapon(Item)) == NextProfile)
            {
                Human.InvManager.SetCurrentWeapon(Weapon(Item));
                return;
            }
    }
}

defaultproperties
{
    BraceFaceClearance=50
    BraceMaxCorrection=30
    BraceSmoothTime=0.06
    NativeLeanAllowance=0.05
    ZedLeanMetres=0.40
    ZedContactGap=25.0
    LeanWallMargin=12.0
    BodyNeckLength=15.0
    // Config defaults are seeded through tools/vr-defaults.json; the SDK
    // ignores config assignments here.
    // Local diffuse fill restores readable first-person albedo in the world
    // pass. KF2 deferred shading supports only Indoor/Outdoor channel bits;
    // using an Unnamed channel silently excluded the old fill from every pixel.
    // A soft NdotL term lights rough surfaces without adding specular glare.
    Begin Object Class=PointLightComponent Name=VRHandFill
        Brightness=0.12
        LightColor=(R=255,G=244,B=232,A=255)
        Radius=120
        FalloffExponent=2
        Hardness=0.25
        bDisableSpecular=true
        CastShadows=false
        CastStaticShadows=false
        CastDynamicShadows=false
        bEnabled=false
        bForceDynamicLight=true
        bCanAffectDynamicPrimitivesOutsideDynamicChannel=true
        bOverrideAutoLightingChannels=true
        LightingChannels=(Indoor=true,Outdoor=true,Dynamic=true,bInitialized=true)
    End Object
    HandFillLight=VRHandFill
    Components.Add(VRHandFill)
    RemoteRole=ROLE_None
    bHidden=false
    WeaponHand=1
    ActiveProfile=-1
    NativeHandlingEnabled=1
    WeaponProfiles(0)=(WeaponClassName=KFWeap_Shotgun_MB500,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Pump,MuzzleSocket=MuzzleFlash,bFirearm=true)
    WeaponProfiles(1)=(WeaponClassName=KFWeap_Pistol_9mm,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,bOneHanded=true,bPistolBrace=true)
    WeaponProfiles(2)=(WeaponClassName=KFWeap_Healer_Syringe,RootBone=RW_Weapon,IdleAnimation=Idle,AlternateKind=2)
    WeaponProfiles(3)=(WeaponClassName=KFWeap_Shotgun_DoubleBarrel,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Barrel,MuzzleSocket=MuzzleFlashLeft,SecondaryMuzzleSocket=MuzzleFlashRight,bFirearm=true,bGripAltFire=true,AlternateKind=2)
    WeaponProfiles(4)=(WeaponClassName=KFWeap_Shotgun_AA12,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,bGripAltFire=true,AlternateKind=1,PrimaryModeLabel="AUTO",AlternateModeLabel="SEMI")
    WeaponProfiles(5)=(WeaponClassName=KFWeap_Shotgun_M4,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true)
    WeaponProfiles(6)=(WeaponClassName=KFWeap_AssaultRifle_AR15,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_ForeGrip,MuzzleSocket=MuzzleFlash,bFirearm=true,bGripAltFire=true,AlternateKind=1,PrimaryModeLabel="BURST",AlternateModeLabel="SEMI")
    // HX25 Idle authors a wrap grip only 6.31 units between wrists. Keep the
    // primary wrist's aim and calibrate support from its own pose on the receiver.
    WeaponProfiles(7)=(WeaponClassName=KFWeap_GrenadeLauncher_HX25,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,bOneHanded=true,bPistolBrace=true)
    WeaponProfiles(8)=(WeaponClassName=KFWeap_Pistol_Medic,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,bOneHanded=true,bPistolBrace=true,bGripAltFire=true,AlternateKind=2)
    WeaponProfiles(9)=(WeaponClassName=KFWeap_Flame_CaulkBurn,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true)
    WeaponProfiles(10)=(WeaponClassName=KFWeap_Rifle_Winchester1894,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true)
    WeaponProfiles(11)=(WeaponClassName=KFWeap_SMG_MP7,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_ForeGrip,MuzzleSocket=MuzzleFlash,bFirearm=true,bGripAltFire=true,AlternateKind=1,PrimaryModeLabel="AUTO",AlternateModeLabel="SEMI")
    WeaponProfiles(12)=(WeaponClassName=KFWeap_Blunt_Crovel,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,bPhysicalMelee=true,MeleeHeadStart=(X=9.3,Y=0.1,Z=34.4),MeleeHeadEnd=(X=-9.3,Y=0.1,Z=34.4),MeleeRadius=6.9)
    WeaponProfiles(13)=(WeaponClassName=KFWeap_Revolver_Rem1858,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,bOneHanded=true,bPistolBrace=true,bUseSharedPistolBrace=true)
    WeaponProfiles(14)=(WeaponClassName=KFWeap_Pistol_Deagle,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,bOneHanded=true,bPistolBrace=true)
    WeaponProfiles(15)=(WeaponClassName=KFWeap_GrenadeLauncher_M79,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Barrel,MuzzleSocket=MuzzleFlash,bFirearm=true,bLaserUsesBoreRotation=true)
    WeaponProfiles(16)=(WeaponClassName=KFWeap_RocketLauncher_RPG7,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true)
    WeaponProfiles(17)=(WeaponClassName=KFWeap_Shotgun_DragonsBreath,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Pump,MuzzleSocket=MuzzleFlash,bFirearm=true)
    WeaponProfiles(18)=(WeaponClassName=KFWeap_AssaultRifle_SCAR,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_ForeGrip,MuzzleSocket=MuzzleFlash,bFirearm=true,bGripAltFire=true,AlternateKind=1,PrimaryModeLabel="AUTO",AlternateModeLabel="SEMI")
    WeaponProfiles(19)=(WeaponClassName=KFWeap_AssaultRifle_AK12,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_ForeGrip,MuzzleSocket=MuzzleFlash,bFirearm=true,bGripAltFire=true,AlternateKind=1,PrimaryModeLabel="AUTO",AlternateModeLabel="BURST")
    WeaponProfiles(20)=(WeaponClassName=KFWeap_Revolver_SW500,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,bOneHanded=true,bPistolBrace=true)
    WeaponProfiles(21)=(WeaponClassName=KFWeap_Flame_Flamethrower,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true)
    WeaponProfiles(22)=(WeaponClassName=KFWeap_Rifle_M14EBR,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,LaserSocket=LaserSight,bFirearm=true)
    WeaponProfiles(23)=(WeaponClassName=KFWeap_Pistol_AF2011,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,bOneHanded=true,bPistolBrace=true)
    WeaponProfiles(24)=(WeaponClassName=KFWeap_Blunt_Pulverizer,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_PumpActionHandle,MuzzleSocket=MuzzleFlash,bPhysicalMelee=true,MeleeHeadStart=(X=-13,Y=0,Z=39.5),MeleeHeadEnd=(X=7,Y=0,Z=39.5),MeleeRadius=7)
    WeaponProfiles(25)=(WeaponClassName=KFWeap_Pistol_Flare,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,bOneHanded=true,bPistolBrace=true,bUseSharedPistolBrace=true)
    WeaponProfiles(26)=(WeaponClassName=KFWeap_Pistol_HRGWinterbite,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,bOneHanded=true,bPistolBrace=true,bUseSharedPistolBrace=true)
    WeaponProfiles(27)=(WeaponClassName=KFWeap_Pistol_G18C,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,bOneHanded=true,bPistolBrace=true,AlternateKind=1,PrimaryModeLabel="AUTO",AlternateModeLabel="SEMI")
    WeaponProfiles(28)=(WeaponClassName=KFWeap_Pistol_ChiappaRhino,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,bOneHanded=true,bPistolBrace=true)
    WeaponProfiles(29)=(WeaponClassName=KFWeap_HRG_93R,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,bOneHanded=true,bPistolBrace=true)
    WeaponProfiles(30)=(WeaponClassName=KFWeap_Pistol_Colt1911,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,bOneHanded=true,bPistolBrace=true)
    WeaponProfiles(31)=(WeaponClassName=KFWeap_HRG_Revolver_Buckshot,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,bOneHanded=true,bPistolBrace=true)
    // Bladed Pistol: swinging the fixed forward blade delivers its stock slash
    // (BASH_FIREMODE); the trigger keeps firing sawblades. Capsule from
    // tools/re/measure_melee_head.py bladedpistol.
    WeaponProfiles(32)=(WeaponClassName=KFWeap_Pistol_Bladed,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,bOneHanded=true,bPistolBrace=true,bPhysicalMelee=true,MeleeHeadStart=(X=26.4,Y=0.5,Z=6.3),MeleeHeadEnd=(X=49,Y=-0.7,Z=6.6),MeleeRadius=5.1)
    WeaponProfiles(33)=(WeaponClassName=KFWeap_Pistol_Blunderbuss,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,bOneHanded=true,bPistolBrace=true,AlternateKind=2)
    WeaponProfiles(34)=(WeaponClassName=KFWeap_Pistol_HRGScorcher,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,bOneHanded=true,bPistolBrace=true,AlternateKind=2)
    WeaponProfiles(35)=(WeaponClassName=KFWeap_Shotgun_HRG_Kaboomstick,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Barrel,MuzzleSocket=MuzzleFlashLeft,SecondaryMuzzleSocket=MuzzleFlashRight,bFirearm=true,AlternateKind=2)
    WeaponProfiles(36)=(WeaponClassName=KFWeap_AssaultRifle_FNFal,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,AlternateKind=1,PrimaryModeLabel="AUTO",AlternateModeLabel="SEMI")
    WeaponProfiles(37)=(WeaponClassName=KFWeap_AssaultRifle_Medic,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,AlternateKind=2)
    WeaponProfiles(38)=(WeaponClassName=KFWeap_AssaultRifle_Bullpup,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Shroud,MuzzleSocket=MuzzleFlash,bFirearm=true,bGripAltFire=true,AlternateKind=1,PrimaryModeLabel="AUTO",AlternateModeLabel="SEMI")
    WeaponProfiles(39)=(WeaponClassName=KFWeap_SMG_P90,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,bGripAltFire=true,AlternateKind=1,PrimaryModeLabel="AUTO",AlternateModeLabel="SEMI")
    WeaponProfiles(40)=(WeaponClassName=KFWeap_SMG_Kriss,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_ForeGrip,MuzzleSocket=MuzzleFlash,bFirearm=true,bGripAltFire=true,AlternateKind=1,PrimaryModeLabel="AUTO",AlternateModeLabel="SEMI")
    WeaponProfiles(41)=(WeaponClassName=KFWeap_HRG_Energy,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,bOneHanded=true,bPistolBrace=true,AlternateKind=1,PrimaryModeLabel="SEMI",AlternateModeLabel="CHARGED")
    WeaponProfiles(43)=(WeaponClassName=KFWeap_Shotgun_HZ12,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_ForeGrip,MuzzleSocket=MuzzleFlash,bFirearm=true)
    WeaponProfiles(44)=(WeaponClassName=KFWeap_Shotgun_ElephantGun,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlashLeft,bFirearm=true,SecondaryMuzzleSocket=MuzzleFlashRight,AlternateKind=2)
    WeaponProfiles(45)=(WeaponClassName=KFWeap_Shotgun_S12,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,AlternateKind=2)
    WeaponProfiles(46)=(WeaponClassName=KFWeap_Shotgun_Nailgun,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,AlternateKind=1,PrimaryModeLabel="SPREAD",AlternateModeLabel="SINGLE")
    WeaponProfiles(49)=(WeaponClassName=KFWeap_HRG_BallisticBouncer,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true)
    WeaponProfiles(50)=(WeaponClassName=KFWeap_AssaultRifle_MKB42,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,AlternateKind=1,PrimaryModeLabel="AUTO",AlternateModeLabel="SEMI")
    WeaponProfiles(55)=(WeaponClassName=KFWeap_SMG_Mac10,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,AlternateKind=1,PrimaryModeLabel="AUTO",AlternateModeLabel="SEMI")
    WeaponProfiles(51)=(WeaponClassName=KFWeap_AssaultRifle_FAMAS,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,bTwoHandBoreAim=true,AlternateKind=2)
    WeaponProfiles(52)=(WeaponClassName=KFWeap_Minigun,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,bPhysicalLowerHandlePrimary=true)
    WeaponProfiles(53)=(WeaponClassName=KFWeap_LMG_Stoner63A,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_ForeGrip,MuzzleSocket=MuzzleFlash,bFirearm=true)
    WeaponProfiles(54)=(WeaponClassName=KFWeap_LMG_MG3,RootBone=RW_Weapon,BoreRotation=(Pitch=16384),IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,AlternateKind=1,PrimaryModeLabel="AUTO",AlternateModeLabel="SPREAD")
    WeaponProfiles(56)=(WeaponClassName=KFWeap_HuskCannon,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true)
    WeaponProfiles(57)=(WeaponClassName=KFWeap_Beam_Microwave,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,AlternateKind=2)
    WeaponProfiles(58)=(WeaponClassName=KFWeap_AssaultRifle_Microwave,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,AlternateKind=1,PrimaryModeLabel="AUTO",AlternateModeLabel="BURST")
    WeaponProfiles(59)=(WeaponClassName=KFWeap_HRG_Dragonbreath,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash01,bFirearm=true,SecondaryMuzzleSocket=MuzzleFlash03,AlternateKind=2)
    // Door-only tool, drawn from the door prompt (VRDoorWelding); not on the wheel.
    // Audited like a gun (build/welder-audit): a one-handed pistol grip whose
    // right hand holds RW_Weapon within 0.4 UU / 1.6 deg through Idle, Idle_Weld
    // and ShootLoop, with the left hand off the tool. bFirearm gives it the
    // controller aim correction and the pointing beam. MuzzleFlash rides
    // RW_Welder_Base, which slides 3.5 UU during welding, so the beam takes the
    // shot's aim rather than that socket's rotation.
    WeaponProfiles(60)=(WeaponClassName=KFWeap_Welder,RootBone=RW_Weapon,IdleAnimation=Idle,MuzzleSocket=MuzzleFlash,bLaserUsesBoreRotation=true,bFirearm=true,bOneHanded=true,AlternateKind=3)
    WeaponProfiles(61)=(WeaponClassName=KFWeap_RocketLauncher_ThermiteBore,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Handle,MuzzleSocket=MuzzleFlash,bFirearm=true,AlternateKind=2)
    WeaponProfiles(62)=(WeaponClassName=KFWeap_AssaultRifle_HRGIncendiaryRifle,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,AlternateKind=2)
    WeaponProfiles(63)=(WeaponClassName=KFWeap_RocketLauncher_Seeker6,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,AlternateKind=1,PrimaryModeLabel="SINGLE",AlternateModeLabel="LOCK-ON")
    WeaponProfiles(64)=(WeaponClassName=KFWeap_RocketLauncher_SealSqueal,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,AlternateKind=2)
    WeaponProfiles(65)=(WeaponClassName=KFWeap_HRG_Crossboom,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,AlternateKind=2)
    WeaponProfiles(66)=(WeaponClassName=KFWeap_HRG_Boomy,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_ForeGrip,MuzzleSocket=MuzzleFlash,bFirearm=true,AlternateKind=1,PrimaryModeLabel="AUTO",AlternateModeLabel="SEMI")
    WeaponProfiles(67)=(WeaponClassName=KFWeap_GrenadeLauncher_M32,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true)
    WeaponProfiles(68)=(WeaponClassName=KFWeap_ZedMKIII,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true)
    WeaponProfiles(69)=(WeaponClassName=KFWeap_GravityImploder,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,AlternateKind=2)
    WeaponProfiles(70)=(WeaponClassName=KFWeap_AssaultRifle_M16M203,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,AlternateKind=2)
    WeaponProfiles(71)=(WeaponClassName=KFWeap_SMG_MP5RAS,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_ForeGrip,MuzzleSocket=MuzzleFlash,bFirearm=true,AlternateKind=1,PrimaryModeLabel="AUTO",AlternateModeLabel="BURST")
    WeaponProfiles(72)=(WeaponClassName=KFWeap_SMG_HK_UMP,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_ForeGripAngle,MuzzleSocket=MuzzleFlash,bFirearm=true,AlternateKind=1,PrimaryModeLabel="AUTO",AlternateModeLabel="BURST")
    WeaponProfiles(73)=(WeaponClassName=KFWeap_AssaultRifle_Thompson,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_ForeGrip,MuzzleSocket=MuzzleFlash,bFirearm=true,AlternateKind=1,PrimaryModeLabel="AUTO",AlternateModeLabel="SEMI")
    WeaponProfiles(74)=(WeaponClassName=KFWeap_AssaultRifle_G36C,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,AlternateKind=1,PrimaryModeLabel="AUTO",AlternateModeLabel="SEMI")
    WeaponProfiles(75)=(WeaponClassName=KFWeap_HRG_Nailgun,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,AlternateKind=1,PrimaryModeLabel="SPREAD",AlternateModeLabel="SINGLE")
    WeaponProfiles(76)=(WeaponClassName=KFWeap_HRG_Stunner,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,AlternateKind=2)
    WeaponProfiles(77)=(WeaponClassName=KFWeap_HRG_BarrierRifle,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_ForeGrip,MuzzleSocket=MuzzleFlash,bFirearm=true,AlternateKind=1)
    // Riot Shield: one-handed Glock; the empty off hand raises the shield (UpdateRiotShield).
    WeaponProfiles(78)=(WeaponClassName=KFWeap_SMG_G18,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,bOneHanded=true,AlternateKind=1,PrimaryModeLabel="AUTO",AlternateModeLabel="SEMI")
    WeaponProfiles(79)=(WeaponClassName=KFWeap_Rifle_CenterfireMB464,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true)
    // Sharpshooter scopes: the M99, Rail Gun and Head Hunter use the physical
    // optic (VRM14Scope). Rail Gun AUTO counts as sighted so it locks (IsSeekerLockOn).
    WeaponProfiles(80)=(WeaponClassName=KFWeap_Rifle_M99,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true)
    WeaponProfiles(81)=(WeaponClassName=KFWeap_Rifle_RailGun,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,AlternateKind=1,PrimaryModeLabel="AUTO",AlternateModeLabel="MANUAL")
    // Mosin: stock melee-base rifle; X/A holds the stock block, X/A + trigger the bayonet bash.
    WeaponProfiles(82)=(WeaponClassName=KFWeap_Rifle_MosinNagant,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,bPhysicalMelee=true,MeleeHeadStart=(X=85.2,Y=0.2,Z=5.9),MeleeHeadEnd=(X=152.1,Y=-1.5,Z=8.1),MeleeRadius=3)
    WeaponProfiles(83)=(WeaponClassName=KFWeap_HRG_CranialPopper,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Housing,MuzzleSocket=MuzzleFlash,bFirearm=true,AlternateKind=2)
    // Crossbow and Corrupter Carbine use the physical optic (VRM14Scope).
    WeaponProfiles(84)=(WeaponClassName=KFWeap_Bow_Crossbow,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true)
    // Compound Bow: the trigger hold draws (stock CompoundBowCharge), release looses.
    // RW_Weapon is the arrow, parked off the rig between shots, so the riser roots it.
    WeaponProfiles(85)=(WeaponClassName=KFWeap_Bow_CompoundBow,RootBone=LW_Weapon,IdleAnimation=Idle,SupportBone=RW_Sight,MuzzleSocket=MuzzleFlash,bFirearm=true,AlternateKind=1,PrimaryModeLabel="SHARP",AlternateModeLabel="CRYO")
    // HRG Beluga Beat: the off hand rides the charging handle it works each shot.
    WeaponProfiles(86)=(WeaponClassName=KFWeap_HRG_SonicGun,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_ChargingHandle,MuzzleSocket=MuzzleFlash,bFirearm=true,AlternateKind=2)
    WeaponProfiles(87)=(WeaponClassName=KFWeap_Rifle_ParasiteImplanter,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,AlternateKind=2)
    WeaponProfiles(88)=(WeaponClassName=KFWeap_SMG_Medic,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,AlternateKind=2)
    WeaponProfiles(89)=(WeaponClassName=KFWeap_Shotgun_Medic,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,AlternateKind=2)
    WeaponProfiles(90)=(WeaponClassName=KFWeap_AssaultRifle_MedicRifleGrenadeLauncher,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,AlternateKind=2)
    WeaponProfiles(91)=(WeaponClassName=KFWeap_Rifle_Hemogoblin,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Housing,MuzzleSocket=MuzzleFlash,bFirearm=true,AlternateKind=2)
    // HRG Incision subclasses the Rail Gun: its targeting locks only while sighted, in both modes,
    // so IsSeekerLockOn keeps it sighted (bUseAltFireMode stays false; X/A + trigger fires the dart).
    WeaponProfiles(92)=(WeaponClassName=KFWeap_Rifle_HRGIncision,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,AlternateKind=2)
    WeaponProfiles(93)=(WeaponClassName=KFWeap_HRG_MedicMissile,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true)
    WeaponProfiles(94)=(WeaponClassName=KFWeap_HRG_Healthrower,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_ActuatorHandle,MuzzleSocket=MuzzleFlash,bFirearm=true,AlternateKind=2)
    WeaponProfiles(95)=(WeaponClassName=KFWeap_HRG_Vampire,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,AlternateKind=2)
    WeaponProfiles(96)=(WeaponClassName=KFWeap_Mine_Reconstructor,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,AlternateKind=2)
    WeaponProfiles(97)=(WeaponClassName=KFWeap_Ice_FreezeThrower,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_ActuatorHandle,MuzzleSocket=MuzzleFlash,bFirearm=true,AlternateKind=2)
    WeaponProfiles(98)=(WeaponClassName=KFWeap_AssaultRifle_LazerCutter,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,AlternateKind=1,PrimaryModeLabel="AUTO",AlternateModeLabel="CHARGE")
    WeaponProfiles(99)=(WeaponClassName=KFWeap_HRG_EMP_ArcGenerator,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,AlternateKind=2)
    WeaponProfiles(100)=(WeaponClassName=KFWeap_HRG_Locust,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,AlternateKind=1,PrimaryModeLabel="SINGLE",AlternateModeLabel="LOCK-ON")
    WeaponProfiles(101)=(WeaponClassName=KFWeap_ShrinkRayGun,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true)
    WeaponProfiles(102)=(WeaponClassName=KFWeap_AssaultRifle_HRGTeslauncher,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,AlternateKind=2)
    WeaponProfiles(103)=(WeaponClassName=KFWeap_Eviscerator,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,bPhysicalMelee=true,MeleeHeadStart=(X=78,Y=0.2,Z=-8.1),MeleeHeadEnd=(X=141.2,Y=0.2,Z=-10.3),MeleeRadius=14)
    // Melee: button-driven stock melee, as the Crovel. Knives and the Bone Crusher
    // (shield on the off arm) are one-handed; all perk knives share the Commando knife anims.
    // Offline Idle measurement: left wrist is 16.6 units lower than the right
    // below the Krampus Axe head. Seat the primary hand at that lower butt grip.
    WeaponProfiles(104)=(WeaponClassName=KFWeap_Edged_AbominationAxe,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,bPhysicalMelee=true,bPhysicalLowerHandlePrimary=true,MeleeHeadStart=(X=33.5,Y=-0.7,Z=55),MeleeHeadEnd=(X=-29.6,Y=-0.1,Z=64),MeleeRadius=11.4)
    WeaponProfiles(105)=(WeaponClassName=KFWeap_Edged_Scythe,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,bPhysicalMelee=true,MeleeHeadStart=(X=1.8,Y=0,Z=69.2),MeleeHeadEnd=(X=-59,Y=0,Z=70.9),MeleeRadius=5)
    // Fire Axe Idle puts the left wrist at Z=-33.3 and right at Z=11.4 while
    // the head is Z=40-42. Its lower left butt grip is the physical primary.
    WeaponProfiles(106)=(WeaponClassName=KFWeap_Edged_FireAxe,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,bPhysicalMelee=true,bPhysicalLowerHandlePrimary=true,MeleeHeadStart=(X=-14.1,Y=0,Z=42),MeleeHeadEnd=(X=14.4,Y=0,Z=40),MeleeRadius=5.3)
    WeaponProfiles(107)=(WeaponClassName=KFWeap_Blunt_MedicBat,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,bPhysicalMelee=true,MeleeHeadStart=(X=1.2,Y=0,Z=37),MeleeHeadEnd=(X=-1.1,Y=0,Z=65.8),MeleeRadius=5.9)
    WeaponProfiles(108)=(WeaponClassName=KFWeap_Edged_IonThruster,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,bPhysicalMelee=true,MeleeHeadStart=(X=0.1,Y=0,Z=86.8),MeleeHeadEnd=(X=-0.1,Y=0,Z=123),MeleeRadius=3)
    WeaponProfiles(109)=(WeaponClassName=KFWeap_Edged_Katana,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,bPhysicalMelee=true,MeleeHeadStart=(X=0,Y=4.9,Z=51),MeleeHeadEnd=(X=0,Y=14.7,Z=90),MeleeRadius=3)
    WeaponProfiles(110)=(WeaponClassName=KFWeap_Blunt_ChainBat,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,bPhysicalMelee=true,MeleeHeadStart=(X=-0.1,Y=0.8,Z=45.5),MeleeHeadEnd=(X=0,Y=-0.5,Z=82.5),MeleeRadius=6)
    WeaponProfiles(111)=(WeaponClassName=KFWeap_Edged_Zweihander,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,bPhysicalMelee=true,MeleeHeadStart=(X=0.1,Y=0,Z=72.1),MeleeHeadEnd=(X=-0.1,Y=0,Z=130.8),MeleeRadius=3)
    WeaponProfiles(112)=(WeaponClassName=KFWeap_Blunt_PowerGloves,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,bOneHanded=true,bPhysicalMelee=true,bPhysicalDualGauntlets=true,MeleeHeadStart=(X=21.9,Y=11.8,Z=-5.1),MeleeHeadEnd=(X=23.2,Y=-7.9,Z=9.7),MeleeRadius=7.1)
    WeaponProfiles(113)=(WeaponClassName=KFWeap_Blunt_MaceAndShield,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,bOneHanded=true,bPhysicalMelee=true,MeleeHeadStart=(X=0,Y=0,Z=48.6),MeleeHeadEnd=(X=0,Y=0,Z=85.8),MeleeRadius=7.4)
    WeaponProfiles(114)=(WeaponClassName=KFWeap_Knife_Commando,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,bOneHanded=true,bPhysicalMelee=true,MeleeHeadStart=(X=-1,Y=0,Z=15),MeleeHeadEnd=(X=0.9,Y=0,Z=27.2),MeleeRadius=3)
    WeaponProfiles(115)=(WeaponClassName=KFWeap_Knife_Gunslinger,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,bOneHanded=true,bPhysicalMelee=true,MeleeHeadStart=(X=-0.6,Y=0,Z=19.7),MeleeHeadEnd=(X=0.9,Y=0,Z=30.3),MeleeRadius=3)
    WeaponProfiles(116)=(WeaponClassName=KFWeap_Knife_Firebug,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,bOneHanded=true,bPhysicalMelee=true,MeleeHeadStart=(X=2.1,Y=0,Z=10.6),MeleeHeadEnd=(X=6.7,Y=0,Z=17.9),MeleeRadius=3)
    WeaponProfiles(117)=(WeaponClassName=KFWeap_Knife_Survivalist,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,bOneHanded=true,bPhysicalMelee=true,MeleeHeadStart=(X=-2.4,Y=0,Z=17.4),MeleeHeadEnd=(X=2.4,Y=0,Z=26.3),MeleeRadius=3)
    WeaponProfiles(118)=(WeaponClassName=KFWeap_Knife_Sharpshooter,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,bOneHanded=true,bPhysicalMelee=true,MeleeHeadStart=(X=-1.8,Y=0,Z=23.3),MeleeHeadEnd=(X=6.9,Y=0,Z=40.3),MeleeRadius=3)
    WeaponProfiles(119)=(WeaponClassName=KFWeap_Knife_Berserker,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,bOneHanded=true,bPhysicalMelee=true,MeleeHeadStart=(X=1.1,Y=0,Z=16.9),MeleeHeadEnd=(X=-1.5,Y=0,Z=29.5),MeleeRadius=3)
    WeaponProfiles(120)=(WeaponClassName=KFWeap_Knife_Support,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,bOneHanded=true,bPhysicalMelee=true,MeleeHeadStart=(X=-1.3,Y=0,Z=16.1),MeleeHeadEnd=(X=-1,Y=0,Z=29.1),MeleeRadius=3)
    WeaponProfiles(121)=(WeaponClassName=KFWeap_Knife_FieldMedic,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,bOneHanded=true,bPhysicalMelee=true,MeleeHeadStart=(X=0.3,Y=0,Z=14),MeleeHeadEnd=(X=0,Y=0,Z=22.5),MeleeRadius=3)
    WeaponProfiles(122)=(WeaponClassName=KFWeap_Knife_SWAT,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,bOneHanded=true,bPhysicalMelee=true,MeleeHeadStart=(X=-1.2,Y=0.1,Z=11),MeleeHeadEnd=(X=-0.6,Y=0.1,Z=20),MeleeRadius=3)
    WeaponProfiles(123)=(WeaponClassName=KFWeap_Knife_Demolitionist,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,bOneHanded=true,bPhysicalMelee=true,MeleeHeadStart=(X=0,Y=0,Z=16.2),MeleeHeadEnd=(X=2.1,Y=0,Z=29.4),MeleeRadius=3)
    // Deployables: squeeze, swing and release the trigger to throw from the hand (VRDeployableHold); X/A + trigger detonates (SecondaryFireMode 5).
    WeaponProfiles(124)=(WeaponClassName=KFWeap_Thrown_C4,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,bOneHanded=true,AlternateKind=2)
    WeaponProfiles(125)=(WeaponClassName=KFWeap_HRG_Warthog,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,bOneHanded=true,AlternateKind=2)
    WeaponProfiles(126)=(WeaponClassName=KFWeap_AutoTurret,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,bOneHanded=true,AlternateKind=2)
    WeaponProfiles(127)=(WeaponClassName=KFWeap_AssaultRifle_Doshinegun,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,AlternateKind=1,PrimaryModeLabel="AUTO",AlternateModeLabel="SEMI")
    WeaponProfiles(128)=(WeaponClassName=KFWeap_HVStormCannon,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true)
    // RAVEN-7 tomahawk: its own rig, KF2VRHands.VRTomahawkRig, whose takes
    // hold the authored right-hand grip (tools/raven7_grip.py). One-handed;
    // capsule in RW_Weapon space from the rig build (VRTomahawk.json
    // melee_capsule). MuzzleFlash is the model origin: remote avatars place
    // the RAVEN-7 attachment by it.
    WeaponProfiles(129)=(WeaponClassName=VRWeap_Tomahawk,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bOneHanded=true,bPhysicalMelee=true,MeleeHeadStart=(X=-9.9,Y=1.3,Z=29),MeleeHeadEnd=(X=14.7,Y=0.6,Z=33.4),MeleeRadius=3)
    // Portal Gun (experimental branch): Portal 2 world model on a KF2 arms rig;
    // grips come from its VR_PrimaryGrip/VR_SupportGrip bones.
    WeaponProfiles(130)=(WeaponClassName=VRWeap_PortalGun,RootBone=RW_Weapon,IdleAnimation=Portal_worldidle,bOneHanded=true)
    // Same authored axe/hand fit; the additional trader axe owns another item.
    WeaponProfiles(131)=(WeaponClassName=VRWeap_TomahawkSecond,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bOneHanded=true,bPhysicalMelee=true,MeleeHeadStart=(X=-9.9,Y=1.3,Z=29),MeleeHeadEnd=(X=14.7,Y=0.6,Z=33.4),MeleeRadius=3)
    // HRG Blast Brawlers: button-driven stock melee (as Crovel). The stock
    // attack fires the shotgun blast and spends a shell; empty trigger reloads.
    WeaponProfiles(48)=(WeaponClassName=KFWeap_HRG_BlastBrawlers,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,bOneHanded=true,bPhysicalMelee=true,bPhysicalDualGauntlets=true,MeleeHeadStart=(X=23.1,Y=13,Z=-4.1),MeleeHeadEnd=(X=28.1,Y=-8.7,Z=9.1),MeleeRadius=7.6)
    // Frost Fang: physical blade swings (stock bash damage/freeze); the trigger
    // keeps the stock shotgun. bFirearm prevents physical-melee input from
    // suppressing that shot; bPhysicalMelee retains the blade and guard.
    // Head capsule spans the underslung axe blade.
    WeaponProfiles(47)=(WeaponClassName=KFWeap_Rifle_FrostShotgunAxe,RootBone=RW_Weapon,IdleAnimation=Idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true,bPhysicalMelee=true,MeleeHeadStart=(X=26,Y=0,Z=-10),MeleeHeadEnd=(X=48,Y=0,Z=-16),MeleeRadius=6.5)
    // The paired members add only ammunition bookkeeping; they override no
    // mesh, animation set or socket, so they keep their parent's authored grip.
    AuditedSubclasses(0)=(SubclassName=VRWeap_Paired9mm,ProfileClassName=KFWeap_Pistol_9mm)
    AuditedSubclasses(1)=(SubclassName=VRWeap_Paired1858,ProfileClassName=KFWeap_Revolver_Rem1858)
    AuditedSubclasses(2)=(SubclassName=VRWeap_PairedAF2011,ProfileClassName=KFWeap_Pistol_AF2011)
    AuditedSubclasses(3)=(SubclassName=VRWeap_PairedDeagle,ProfileClassName=KFWeap_Pistol_Deagle)
    AuditedSubclasses(4)=(SubclassName=VRWeap_PairedSW500,ProfileClassName=KFWeap_Revolver_SW500)
    AuditedSubclasses(5)=(SubclassName=VRWeap_PairedFlare,ProfileClassName=KFWeap_Pistol_Flare)
    AuditedSubclasses(6)=(SubclassName=VRWeap_PairedWinterbite,ProfileClassName=KFWeap_Pistol_HRGWinterbite)
    AuditedSubclasses(7)=(SubclassName=VRWeap_PairedG18C,ProfileClassName=KFWeap_Pistol_G18C)
    AuditedSubclasses(8)=(SubclassName=VRWeap_PairedChiappaRhino,ProfileClassName=KFWeap_Pistol_ChiappaRhino)
    AuditedSubclasses(9)=(SubclassName=VRWeap_Paired93R,ProfileClassName=KFWeap_HRG_93R)
    AuditedSubclasses(10)=(SubclassName=VRWeap_PairedColt1911,ProfileClassName=KFWeap_Pistol_Colt1911)
    AuditedSubclasses(11)=(SubclassName=VRWeap_PairedBuckshot,ProfileClassName=KFWeap_HRG_Revolver_Buckshot)
    AuditedSubclasses(12)=(SubclassName=VRWeap_PairedBladed,ProfileClassName=KFWeap_Pistol_Bladed)
    // Optional package alias only; this name does not load or enable its content.
    AuditedSubclasses(13)=(SubclassName=BreacherDeadbolt,ProfileClassName=KFWeap_HRG_Nailgun)
    ControllerFitProfiles(0)=(ProfileId=Quest2,Label="LEGACY QUEST 2 FIT",FirearmPitchDegrees=-8.6,FirearmYawDegrees=0.0,FirearmRollDegrees=0.0)
    Quest2WristOffset=(X=-6.0,Y=4.1,Z=0.7)
    ControllerFitProfiles(1)=(ProfileId=Neutral,Label="RAW OPENXR AIM",FirearmPitchDegrees=0.0,FirearmYawDegrees=0.0,FirearmRollDegrees=0.0)
    // Arizona Sunshine 2's hold: its PrimaryTrigger slot (60 degrees from the
    // raw pose) leaves the barrel 20.6 degrees below the OpenXR aim ray.
    ControllerFitProfiles(2)=(ProfileId=Relaxed,Label="RELAXED WRIST (AS2)",FirearmPitchDegrees=-20.6,FirearmYawDegrees=0.0,FirearmRollDegrees=0.0)
    JumpBindIndex=-1
    UseBindIndex=-1
    FloatingHandsMesh=SkeletalMesh'KF2VRHands.VRFloatingHands'
    FloatingHandsMaterial=MaterialInstanceConstant'CHR_1P_Arms_MAT.CHR_Master_1stP_Arms_MIC'
    Hands(0)=(SupportOwner=-1)
    Hands(1)=(SupportOwner=-1)
    TickGroup=TG_PreAsyncWork
}
