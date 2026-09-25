///|
pub(all) suberror BundleError {
  BundleError(String)
} derive(Eq, Debug)

///|
pub(all) struct CapturedSource {
  material : @config.ReloadMaterial
  bytes : Bytes
}

///|
pub struct CapturedBundle {
  manifest : @config.ReloadManifest
  sources : Array[CapturedSource]
}

///|
pub fn CapturedBundle::manifest(
  self : CapturedBundle,
) -> @config.ReloadManifest {
  self.manifest
}

///|
pub fn CapturedBundle::sources(self : CapturedBundle) -> Array[CapturedSource] {
  self.sources.copy()
}

///|
fn copy_native_bytes(value : Bytes, target : Array[Byte]) -> Unit {
  for byte in value {
    target.push(byte)
  }
}

///|
/// The worker's slot and native-owned bytes remain reserved through completion
/// and every 4 KiB copy. Cancellation waits for actual completion and reap.
async fn capture_one(
  worker : @native.CaptureWorker,
  task_id : Int64,
  path : String,
  max_bytes : Int,
  private_file : Bool,
) -> (Bytes, Bytes) {
  match worker.submit(task_id, path, max_bytes, private_file~) {
    Ok(_) => ()
    Err(_) => raise BundleError("source capture unavailable")
  }
  let mut active = true
  errdefer @async.protect_from_cancel(() => {
    if active {
      ignore(worker.cancel(task_id))
      for ;; {
        if worker.poll() is Some(_) {
          ignore(worker.reap(task_id))
          break
        }
        @async.sleep(1)
      }
    }
  })
  for ;; {
    if worker.poll() is Some(id) {
      if id != task_id {
        raise BundleError("source capture completion mismatch")
      }
      break
    }
    @async.sleep(1)
  }
  let (length, digest) = match worker.result_info(task_id) {
    Ok(value) => value
    Err(@native.SourceChanged) => raise BundleError("source_changed")
    Err(_) => raise BundleError("source capture rejected")
  }
  let output : Array[Byte] = []
  let mut offset = 0
  while offset < length {
    let chunk = match worker.copy_chunk(task_id, offset) {
      Ok(value) => value
      Err(_) => raise BundleError("source capture copy failed")
    }
    if chunk.length() < 1 ||
      chunk.length() > 4096 ||
      chunk.length() > length - offset {
      raise BundleError("source capture length mismatch")
    }
    copy_native_bytes(chunk, output)
    offset += chunk.length()
    @async.sleep(1)
  }
  if worker.reap(task_id) is Err(_) {
    raise BundleError("source capture reap failed")
  }
  active = false
  (Bytes::from_array(output), digest)
}

///|
async fn stop_worker(worker : @native.CaptureWorker) -> Unit {
  @async.protect_from_cancel(() => {
    for ;; {
      if worker.stop() {
        break
      }
      @async.sleep(1)
    }
    if !worker.destroy() {
      abort("source capture worker failed to destroy after stop")
    }
  })
}

///|
/// Captures one complete manifest-selected bundle. Config and policy parsing,
/// effective-path comparison, and activation are separate gates.
pub async fn capture_bundle(
  manifest_path : String,
  max_source_bytes? : Int = 16777216,
) -> CapturedBundle {
  if max_source_bytes < 16384 || max_source_bytes > 67108864 {
    raise BundleError("invalid source byte budget")
  }
  let worker = match @native.CaptureWorker::new() {
    Ok(value) => value
    Err(_) => raise BundleError("source capture backend unavailable")
  }
  errdefer stop_worker(worker)
  let (manifest_bytes, manifest_digest) = capture_one(
    worker, 1L, manifest_path, 16384, true,
  )
  let text = @utf8.decode(manifest_bytes) catch {
    _ => raise BundleError("manifest must be UTF-8")
  }
  let manifest = @config.parse_reload_manifest(text) catch {
    _ => raise BundleError("invalid bundle manifest")
  }
  let sources : Array[CapturedSource] = []
  let mut total = manifest_bytes.length()
  let mut next_id = 2L
  for material in manifest.materials {
    let private_file = material.role == "passwords" ||
      material.role == "mqtt_key"
    let (bytes, digest) = capture_one(
      worker,
      next_id,
      material.path,
      1048576,
      private_file,
    )
    next_id += 1L
    if digest != material.sha256 {
      raise BundleError("source_changed")
    }
    if bytes.length() > max_source_bytes - total {
      raise BundleError("bundle source budget exceeded")
    }
    total += bytes.length()
    sources.push({ material, bytes })
  }
  let (final_manifest, final_digest) = capture_one(
    worker, next_id, manifest_path, 16384, true,
  )
  if final_digest != manifest_digest || final_manifest != manifest_bytes {
    raise BundleError("source_changed")
  }
  stop_worker(worker)
  { manifest, sources }
}
