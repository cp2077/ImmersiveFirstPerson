public static native func ImmersiveFirstPerson_IsHeadLookAtEnabled() -> Bool;

// Generic AI normally aims at Chest. Record whether each generic entity task is
// targeting V, then redirect only that task to Head. NPC-to-NPC gaze is unchanged.
// This feature is independent of the optional runtime-height animgraph.
@addField(AIGenericLookatTask)
private let m_ifpTargetIsPlayer: Bool;

@addMethod(AIGenericLookatTask)
protected final func IFPSetTargetIsPlayer(value: Bool) -> Void {
  this.m_ifpTargetIsPlayer = value;
}

@wrapMethod(AIGenericEntityLookatTask)
protected func ShouldLookatBeActive(context: ScriptExecutionContext) -> Bool {
  let active: Bool = wrappedMethod(context);
  this.IFPSetTargetIsPlayer(active && IsDefined(this.m_lookatTarget as PlayerPuppet));
  return active;
}

@wrapMethod(AIGenericAdvancedLookatTask)
protected func ShouldLookatBeActive(context: ScriptExecutionContext) -> Bool {
  let active: Bool = wrappedMethod(context);
  this.IFPSetTargetIsPlayer(active && IsDefined(this.m_lookatTarget as PlayerPuppet));
  return active;
}

@wrapMethod(AIGenericLookatTask)
protected func GetLookAtSlotName() -> CName {
  let slotName: CName = wrappedMethod();
  if ImmersiveFirstPerson_IsHeadLookAtEnabled()
    && this.m_ifpTargetIsPlayer
    && Equals(slotName, n"Chest") {
    return n"Head";
  };
  return slotName;
}
