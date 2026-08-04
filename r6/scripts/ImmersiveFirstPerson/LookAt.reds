// Keep look-at state in REDscript so a missing or version-rejected native plugin
// cannot leave behind an invalid native declaration that blocks game startup.
@addField(PlayerPuppet)
private let m_ifpHeadLookAtEnabled: Bool;

@addMethod(PlayerPuppet)
public final func ImmersiveFirstPersonSetHeadLookAtEnabled(enabled: Bool) -> Bool {
  this.m_ifpHeadLookAtEnabled = enabled;
  return true;
}

@addMethod(PlayerPuppet)
public final func ImmersiveFirstPersonIsHeadLookAtEnabled() -> Bool {
  return this.m_ifpHeadLookAtEnabled;
}

// Generic AI normally aims at Chest. Record whether each generic entity task is
// targeting V, then redirect only that task to Head. NPC-to-NPC gaze is unchanged.
// This feature is independent of the optional runtime-height animgraph.
@addField(AIGenericLookatTask)
private let m_ifpTargetPlayer: wref<PlayerPuppet>;

@addMethod(AIGenericLookatTask)
protected final func IFPSetTargetPlayer(value: wref<PlayerPuppet>) -> Void {
  this.m_ifpTargetPlayer = value;
}

@wrapMethod(AIGenericEntityLookatTask)
protected func ShouldLookatBeActive(context: ScriptExecutionContext) -> Bool {
  let active: Bool = wrappedMethod(context);
  if active {
    this.IFPSetTargetPlayer(this.m_lookatTarget as PlayerPuppet);
  } else {
    this.IFPSetTargetPlayer(null);
  };
  return active;
}

@wrapMethod(AIGenericAdvancedLookatTask)
protected func ShouldLookatBeActive(context: ScriptExecutionContext) -> Bool {
  let active: Bool = wrappedMethod(context);
  if active {
    this.IFPSetTargetPlayer(this.m_lookatTarget as PlayerPuppet);
  } else {
    this.IFPSetTargetPlayer(null);
  };
  return active;
}

@wrapMethod(AIGenericLookatTask)
protected func GetLookAtSlotName() -> CName {
  let slotName: CName = wrappedMethod();
  if IsDefined(this.m_ifpTargetPlayer)
    && this.m_ifpTargetPlayer.ImmersiveFirstPersonIsHeadLookAtEnabled()
    && Equals(slotName, n"Chest") {
    return n"Head";
  };
  return slotName;
}
