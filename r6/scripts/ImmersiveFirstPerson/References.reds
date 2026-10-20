// A wref return lets CET retain session objects without owning their lifetime.
public abstract class ImmersiveFirstPersonRef {
  public static func Weak(object: ref<IScriptable>) -> wref<IScriptable> {
    return object;
  }
}
