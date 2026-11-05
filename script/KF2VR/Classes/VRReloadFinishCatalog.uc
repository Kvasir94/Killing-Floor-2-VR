// Only authored, hand-operated finishing controls. Motor spinners, passive
// feed mechanisms and energy weapons without a control keep their stock tail.
class VRReloadFinishCatalog extends Object;

struct FinishProfile
{
    var class<KFWeapon> WeaponClass;
    var name Bone;
    var float StartTime, EndTime, GripTime, FinishTime;
    var string Sound, ReturnSound, AcquireSound, Prompt;
    var name ReferenceClip, FollowBones[12];
    var byte SourceHand;
    var float SoundTime, ReturnStart, ReturnEnd, FingerLimit;
    var bool bEliteOnly, bRegularOnly, bSoundless, bNearAmmoAction;
    // Contact press, one-way pull, or out-and-back actuation.
    var byte Kind;
    var bool bEmptyOnly;
};
var array<FinishProfile> Profiles;

static function int Find(KFWeapon W, bool bEmpty, optional AnimSequence AcceptedSequence)
{
    local int I, J;
    local float AmmoTime;
    local AnimSequence Seq;
    local AnimNotify_AkEvent Event;
    local bool bElite;
    if (W == None) return -1;
    // The Thermite exhaust is powered; stock closes it after insertion.
    if (W.Class == class'KFWeap_RocketLauncher_ThermiteBore') return -1;
    Seq = AcceptedSequence;
    if (Seq == None && W.WeaponAnimSeqNode != None) Seq = W.WeaponAnimSeqNode.AnimSeq;
    if (Seq == None) return -1;
    bElite = InStr(Caps(string(Seq.SequenceName)), "ELITE") >= 0;
    AmmoTime = -1;
    for (J = 0; J < Seq.Notifies.Length; ++J)
        if (KFAnimNotify_ReloadAmmo(Seq.Notifies[J].Notify) != None) AmmoTime = Seq.Notifies[J].Time;
    if (AmmoTime < 0) return -1;
    for (I = 0; I < default.Profiles.Length; ++I)
    {
        if (class'VRReloadCatalog'.static.ProfileClass(W.Class) != default.Profiles[I].WeaponClass
            || (!bEmpty && default.Profiles[I].bEmptyOnly)) continue;
        if ((default.Profiles[I].bEliteOnly && !bElite) || (default.Profiles[I].bRegularOnly && bElite)) continue;
        if (default.Profiles[I].bSoundless) return I;
        // Fast perk clips that omit this actuation keep their authored route.
        for (J = 0; J < Seq.Notifies.Length; ++J)
        {
            Event = AnimNotify_AkEvent(Seq.Notifies[J].Notify);
            if (Event != None && Event.AkEvent != None && Seq.Notifies[J].Time > AmmoTime - (default.Profiles[I].bNearAmmoAction ? 0.25 : 0.0)
                && PathName(Event.AkEvent) ~= default.Profiles[I].Sound) return I;
        }
    }
    return -1;
}

defaultproperties
{
    // Helios: the button is pressed; its subsequent charger spin is powered.
    Profiles(0)=(WeaponClass=class'KFWeap_AssaultRifle_Microwave',Bone=RW_Charger,StartTime=2.30,EndTime=2.34,GripTime=2.31,SoundTime=2.314334,FinishTime=2.36,Kind=0,bEmptyOnly=true,Sound="WW_WEP_Helios.Play_WEP_Helios_Handling_Button_Press",Prompt="PRESS CHARGE BUTTON")
    // These handles close the battery latch; the later retract/spin is powered.
    Profiles(1)=(WeaponClass=class'KFWeap_Beam_Microwave',Bone=RW_Handle1,StartTime=2.42,EndTime=2.53,GripTime=2.50,SoundTime=2.94768,FinishTime=2.55,Kind=0,Sound="WW_WEP_SA_Microwave_Gun.Play_SA_MicrowaveGun_Handling_HandleIn",Prompt="PRESS BATTERY LATCH")
    Profiles(2)=(WeaponClass=class'KFWeap_HRG_EMP_ArcGenerator',Bone=RW_Handle1,StartTime=2.42,EndTime=2.53,GripTime=2.50,SoundTime=2.94768,FinishTime=2.55,Kind=0,Sound="WW_WEP_SA_Microwave_Gun.Play_SA_MicrowaveGun_Handling_HandleIn",Prompt="PRESS BATTERY LATCH")
    // The nailgun pumps the air latch up and back down, not a chamber rack.
    Profiles(3)=(WeaponClass=class'KFWeap_Shotgun_Nailgun',Bone=RW_Mag_Release,StartTime=1.90,EndTime=2.08,GripTime=1.96,SoundTime=1.945864,ReturnStart=2.08,ReturnEnd=2.26,FinishTime=2.26,Kind=2,bEmptyOnly=true,Sound="WW_WEP_SA_Nailgun.Play_WEP_SA_Nailgun_Handling_AirUp",ReturnSound="WW_WEP_SA_Nailgun.Play_WEP_SA_Nailgun_Handling_AirDown",Prompt="LIFT AND RETURN AIR LEVER")
    Profiles(4)=(WeaponClass=class'KFWeap_HRG_Nailgun',Bone=RW_Mag_Release,StartTime=1.90,EndTime=2.08,GripTime=1.96,SoundTime=1.945864,ReturnStart=2.08,ReturnEnd=2.26,FinishTime=2.26,Kind=2,bEmptyOnly=true,Sound="WW_WEP_SA_Nailgun.Play_WEP_SA_Nailgun_Handling_AirUp",ReturnSound="WW_WEP_SA_Nailgun.Play_WEP_SA_Nailgun_Handling_AirDown",Prompt="LIFT AND RETURN AIR LEVER")
    // Railgun/Incision: pull the authored bolt to release the powered feed.
    Profiles(5)=(WeaponClass=class'KFWeap_Rifle_RailGun',Bone=RW_Bolt,StartTime=1.35,EndTime=1.62,GripTime=1.40,SoundTime=1.409584,FinishTime=1.62,Kind=1,Sound="WW_WEP_SA_Railgun.Play_Railgun_Reload_Pull",Prompt="PULL FEED HANDLE")
    Profiles(6)=(WeaponClass=class'KFWeap_Rifle_HRGIncision',Bone=RW_Bolt,StartTime=1.35,EndTime=1.62,GripTime=1.40,SoundTime=1.409584,FinishTime=1.62,Kind=1,Sound="WW_WEP_SA_Railgun.Play_Railgun_Reload_Pull",Prompt="PULL FEED HANDLE")
    Profiles(7)=(WeaponClass=class'KFWeap_Ice_FreezeThrower',Bone=RW_ActuatorHandle,StartTime=2.66,EndTime=3.35,GripTime=3.10,SoundTime=2.873626,FinishTime=3.42,Kind=1,bRegularOnly=true,Sound="WW_WEP_Cryo_Gun.Play_Cryo_Gun_Reload_End",Prompt="CLOSE CANISTER ACTUATOR",FollowBones[0]=RW_Actuator01,FollowBones[1]=RW_Actuator02,FollowBones[2]=RW_Actuator03,FollowBones[3]=RW_Actuator04,FollowBones[4]=RW_Actuator05,FollowBones[5]=RW_FreezeChamber,FollowBones[6]=RW_Magazine1,FollowBones[7]=RW_WireWrap02)
    Profiles(8)=(WeaponClass=class'KFWeap_HRG_Healthrower',Bone=RW_ActuatorHandle,StartTime=2.66,EndTime=3.35,GripTime=3.10,SoundTime=2.873626,FinishTime=3.42,Kind=1,bRegularOnly=true,Sound="WW_WEP_Cryo_Gun.Play_Cryo_Gun_Reload_End",Prompt="CLOSE CANISTER ACTUATOR",FollowBones[0]=RW_Actuator01,FollowBones[1]=RW_Actuator02,FollowBones[2]=RW_Actuator03,FollowBones[3]=RW_Actuator04,FollowBones[4]=RW_Actuator05,FollowBones[5]=RW_FreezeChamber,FollowBones[6]=RW_Magazine1,FollowBones[7]=RW_WireWrap02)
    Profiles(9)=(WeaponClass=class'KFWeap_GravityImploder',Bone=RW_Lever,StartTime=2.95,EndTime=3.18,ReturnStart=3.18,ReturnEnd=3.40,GripTime=3.06,SoundTime=3.037416,FinishTime=3.42,Kind=2,bEmptyOnly=true,bRegularOnly=true,Sound="WW_WEP_Gravity_Imploder.Play_WEP_Gravity_Imploder_Bullet_Out",Prompt="PULL AND RETURN LEVER")
    Profiles(10)=(WeaponClass=class'KFWeap_Blunt_Pulverizer',Bone=RW_PumpActionHandle,StartTime=2.78,EndTime=2.95,GripTime=2.85,SoundTime=2.85363,FinishTime=3.00,Kind=1,SourceHand=1,Sound="WW_WEP_MEL_Pulverizer.Play_WEP_MEL_Pulverizer_Handle_HandleUp",Prompt="RAISE PUMP HANDLE")
    Profiles(11)=(WeaponClass=class'KFWeap_Pistol_Blunderbuss',Bone=RW_Hammer,StartTime=1.60,EndTime=1.85,GripTime=1.72,SoundTime=1.552667,FinishTime=1.86,Kind=0,SourceHand=1,bEmptyOnly=true,Sound="WW_WEP_Blunderbuss.Play_WEP_Blunderbuss_Handling_Reload_C",Prompt="COCK HAMMER")
    Profiles(12)=(WeaponClass=class'KFWeap_Flame_CaulkBurn',Bone=RW_Charging_Handle,StartTime=2.80,EndTime=3.15,GripTime=2.80,SoundTime=2.998,FinishTime=3.17,Kind=0,FingerLimit=28,Sound="WW_WEP_SA_CaulkBurn.Play_SA_CaulkBurn_Handling_Handle_Engage",Prompt="RELEASE FEED HANDLE")
    Profiles(13)=(WeaponClass=class'KFWeap_Flame_Flamethrower',Bone=RW_GasTank_Release,StartTime=3.12,EndTime=3.28,GripTime=3.20,SoundTime=3.186,FinishTime=3.30,Kind=1,FingerLimit=24,Sound="WW_WEP_SA_Flamethrower.Play_WEP_SA_Flamethrower_Handling_Lever_Close",Prompt="CLOSE TANK LEVER")
    Profiles(14)=(WeaponClass=class'KFWeap_RocketLauncher_ThermiteBore',Bone=RW_Exhaust,StartTime=2.50,EndTime=2.60,GripTime=2.55,FinishTime=2.62,Kind=0,bEmptyOnly=true,bRegularOnly=true,bSoundless=true,Prompt="CLOSE EXHAUST LATCH")
    Profiles(15)=(WeaponClass=class'KFWeap_Pistol_Bladed',Bone=RW_FrontPivot,StartTime=1.35,EndTime=1.45,GripTime=1.40,SoundTime=1.393463,FinishTime=1.46,Kind=0,bEmptyOnly=true,Sound="WW_WEP_BladedPistol.Play_WEP_BlandedPistol_Reload_D",Prompt="PRESS FRONT LATCH")
    Profiles(16)=(WeaponClass=class'KFWeap_RocketLauncher_Seeker6',Bone=RW_MagReleaseHandle1,StartTime=2.60,EndTime=2.76,ReturnStart=2.95,ReturnEnd=3.30,GripTime=2.65,SoundTime=2.647915,FinishTime=3.31,Kind=2,bRegularOnly=true,Sound="WW_WEP_Seeker_6.Play_Seeker_6_Reload_Handle_FWD",ReturnSound="WW_WEP_Seeker_6.Play_Seeker_6_Reload_Handle_Back",Prompt="PUSH AND RETURN FEED HANDLE",FollowBones[0]=RW_MagRelease1,FollowBones[1]=RW_MagReleaseSlide1,FollowBones[2]=RW_MagReleaseSlideCollapse1)
    Profiles(17)=(WeaponClass=class'KFWeap_HRG_Locust',Bone=RW_MagReleaseHandle1,StartTime=2.60,EndTime=2.76,ReturnStart=2.95,ReturnEnd=3.30,GripTime=2.65,SoundTime=2.647915,FinishTime=3.31,Kind=2,bRegularOnly=true,Sound="WW_WEP_HRG_Locust.Play_WEP_HRG_Locust_Handle_Reload",ReturnSound="WW_WEP_Seeker_6.Play_Seeker_6_Reload_Handle_Back",Prompt="PUSH AND RETURN FEED HANDLE",FollowBones[0]=RW_MagRelease1,FollowBones[1]=RW_MagReleaseSlide1,FollowBones[2]=RW_MagReleaseSlideCollapse1)
    Profiles(18)=(WeaponClass=class'KFWeap_RocketLauncher_Seeker6',Bone=RW_MagReleaseHandle1,ReferenceClip=Reload_Empty_Elite,StartTime=2.52,EndTime=2.68,GripTime=2.65,SoundTime=2.75417,FinishTime=2.88,Kind=1,bEliteOnly=true,Sound="WW_WEP_Seeker_6.Play_Seeker_6_Reload_Handle_Back",Prompt="PULL FEED HANDLE",FollowBones[0]=RW_MagRelease1,FollowBones[1]=RW_MagReleaseSlide1,FollowBones[2]=RW_MagReleaseSlideCollapse1)
    Profiles(19)=(WeaponClass=class'KFWeap_HRG_Locust',Bone=RW_MagReleaseHandle1,ReferenceClip=Reload_Empty_Elite,StartTime=2.52,EndTime=2.68,GripTime=2.65,SoundTime=2.647915,FinishTime=2.88,Kind=1,bEliteOnly=true,Sound="WW_WEP_HRG_Locust.Play_WEP_HRG_Locust_Handle_Reload",Prompt="PULL FEED HANDLE",FollowBones[0]=RW_MagRelease1,FollowBones[1]=RW_MagReleaseSlide1,FollowBones[2]=RW_MagReleaseSlideCollapse1)
    Profiles(20)=(WeaponClass=class'KFWeap_Rifle_ParasiteImplanter',Bone=RW_Bolt,StartTime=1.30,EndTime=1.77,ReturnStart=2.03,ReturnEnd=2.55,GripTime=1.55,SoundTime=1.62583,FinishTime=2.57,Kind=2,SourceHand=1,bEmptyOnly=true,Sound="WW_WEP_ParasiteImplanter.Play_CorrupterCarbine_Reload_D",ReturnSound="WW_WEP_ParasiteImplanter.Play_CorrupterCarbine_Reload_E",AcquireSound="WW_WEP_ParasiteImplanter.Play_CorrupterCarbine_Reload_C",Prompt="LIFT PULL AND RETURN BOLT")
    Profiles(21)=(WeaponClass=class'KFWeap_RocketLauncher_ThermiteBore',Bone=RW_Exhaust,ReferenceClip=Reload_Empty_Elite,StartTime=1.54,EndTime=1.62,GripTime=1.60,SoundTime=1.652,FinishTime=1.64,Kind=0,bEmptyOnly=true,bEliteOnly=true,Sound="WW_WEP_Thermite.Play_WEP_Thermite_Forward_Close",Prompt="CLOSE EXHAUST LATCH")
    Profiles(22)=(WeaponClass=class'KFWeap_GravityImploder',Bone=RW_Lever,ReferenceClip=Reload_Empty_Elite,StartTime=2.10,EndTime=2.22,ReturnStart=2.30,ReturnEnd=2.40,GripTime=2.20,SoundTime=2.245,FinishTime=2.42,Kind=2,bEmptyOnly=true,bEliteOnly=true,Sound="WW_WEP_Gravity_Imploder.Play_WEP_Gravity_Imploder_Reload",Prompt="PULL AND RETURN LEVER")
    Profiles(23)=(WeaponClass=class'KFWeap_Ice_FreezeThrower',Bone=RW_ActuatorHandle,ReferenceClip=Reload_Empty_Elite,StartTime=2.275,EndTime=2.85,GripTime=2.55,SoundTime=2.169,FinishTime=2.90,Kind=1,bEliteOnly=true,bNearAmmoAction=true,Sound="WW_WEP_Cryo_Gun.Play_Cryo_Gun_Reload_End",Prompt="CLOSE CANISTER ACTUATOR",FollowBones[0]=RW_Actuator01,FollowBones[1]=RW_Actuator02,FollowBones[2]=RW_Actuator03,FollowBones[3]=RW_Actuator04,FollowBones[4]=RW_Actuator05,FollowBones[5]=RW_FreezeChamber,FollowBones[6]=RW_Magazine1,FollowBones[7]=RW_WireWrap02)
    Profiles(24)=(WeaponClass=class'KFWeap_HRG_Healthrower',Bone=RW_ActuatorHandle,ReferenceClip=Reload_Empty_Elite,StartTime=2.275,EndTime=2.85,GripTime=2.55,SoundTime=2.169,FinishTime=2.90,Kind=1,bEliteOnly=true,bNearAmmoAction=true,Sound="WW_WEP_Cryo_Gun.Play_Cryo_Gun_Reload_End",Prompt="CLOSE CANISTER ACTUATOR",FollowBones[0]=RW_Actuator01,FollowBones[1]=RW_Actuator02,FollowBones[2]=RW_Actuator03,FollowBones[3]=RW_Actuator04,FollowBones[4]=RW_Actuator05,FollowBones[5]=RW_FreezeChamber,FollowBones[6]=RW_Magazine1,FollowBones[7]=RW_WireWrap02)
    // Port loading leaves the M4 bolt locked back until the release is pressed.
    // The stock fingers press the release 11.3 UU from the RW_Bolt pivot at the
    // regular grip time (scripted replay, 11-01), so the limit allows 12.
    Profiles(25)=(WeaponClass=class'KFWeap_Shotgun_M4',Bone=RW_Bolt,ReferenceClip=Reload_Open_Shell,StartTime=1.10,EndTime=1.22,GripTime=1.13,SoundTime=1.169833,FinishTime=1.23,Kind=0,bEmptyOnly=true,bRegularOnly=true,bNearAmmoAction=true,FingerLimit=12,Sound="WW_WEP_SA_M4.Play_WEP_SA_M4_Handling_BoltForward",Prompt="RELEASE BOLT")
    Profiles(26)=(WeaponClass=class'KFWeap_Shotgun_M4',Bone=RW_Bolt,ReferenceClip=Reload_Open_Shell_Elite,StartTime=0.88,EndTime=0.97,GripTime=0.90,SoundTime=0.923507,FinishTime=0.98,Kind=0,bEmptyOnly=true,bEliteOnly=true,bNearAmmoAction=true,FingerLimit=12,Sound="WW_WEP_SA_M4.Play_WEP_SA_M4_Handling_BoltForward",Prompt="RELEASE BOLT")
}
