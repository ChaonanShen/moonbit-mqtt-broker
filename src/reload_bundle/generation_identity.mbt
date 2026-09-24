///|
/// Compare the effective runtime values and captured non-config material
/// digests. Editing a comment or whitespace in config does not create a new
/// generation; changing any security or TLS byte does.
pub fn CapturedBundle::same_effective_generation(
  self : CapturedBundle,
  candidate : ReloadEffectiveCandidate,
  previous : CapturedBundle,
  previous_candidate : ReloadEffectiveCandidate,
) -> Bool {
  if !candidate.restart_compatible(previous_candidate) ||
    candidate.hot() != previous_candidate.hot() ||
    self.manifest.materials.length() != previous.manifest.materials.length() {
    return false
  }
  for material in self.manifest.materials {
    if material.role == "config" {
      continue
    }
    let mut matched = false
    for before in previous.manifest.materials {
      if before.role == material.role &&
        before.listener_id == material.listener_id &&
        before.path == material.path &&
        before.sha256 == material.sha256 {
        matched = true
        break
      }
    }
    if !matched {
      return false
    }
  }
  true
}
