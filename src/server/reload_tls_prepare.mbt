///|
pub struct PreparedTlsGeneration {
  leases : Array[(String, TlsMaterialLease)]
  mut transferred : Bool
}

///|
pub fn PreparedTlsGeneration::release(self : PreparedTlsGeneration) -> Unit {
  if self.transferred {
    return
  }
  self.transferred = true
  for item in self.leases {
    let (_, lease) = item
    lease.release()
  }
}

///|
/// The provider takes every root reference at one non-awaiting event boundary.
pub fn PreparedTlsGeneration::publish(
  self : PreparedTlsGeneration,
  provider : TlsMaterialProvider,
) -> Bool {
  if self.transferred || !provider.publish_generation(self.leases) {
    return false
  }
  self.transferred = true
  true
}

///|
async fn finish_tls_worker(worker : @native.CaptureWorker) -> Unit {
  @async.protect_from_cancel(() => {
    for ;; {
      if worker.stop() {
        break
      }
      @async.sleep(1)
    }
    if !worker.destroy() {
      abort("TLS maintenance worker did not drain")
    }
  })
}

///|
async fn prepare_tls_lease(
  worker : @native.CaptureWorker,
  task_id : Int64,
  source : TlsServerConfig,
  cert : Bytes,
  key : Bytes,
  ticket : @budget.Ticket,
) -> TlsMaterialLease {
  if worker.submit_tls(task_id, cert, key) is Err(_) {
    raise ResourceStartupFailure("TLS maintenance submission failed")
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
    match worker.poll() {
      Some(id) if id == task_id => break
      Some(_) =>
        raise ResourceStartupFailure("TLS maintenance completion mismatch")
      None => @async.sleep(1)
    }
  }
  let directory = match worker.take_tls_directory(task_id) {
    Ok(value) => value
    Err(_) => raise ResourceStartupFailure("TLS material validation failed")
  }
  if worker.reap(task_id) is Err(_) {
    raise ResourceStartupFailure("TLS material reap failed")
  }
  active = false
  TlsMaterialLease::from_prepared_directory(source, directory, ticket~)
}

///|
/// The caller owns the returned candidate and must publish or release it.
/// All cert/key bytes came from one verified bundle; source files are not read.
pub async fn prepare_tls_generation(
  bundle : @bundle.CapturedBundle,
  candidate : @bundle.ReloadEffectiveCandidate,
  pool : @budget.Pool,
) -> PreparedTlsGeneration {
  let hot = candidate.hot()
  let leases : Array[(String, TlsMaterialLease)] = []
  if hot.tls_sources.is_empty() {
    return { leases, transferred: false }
  }
  let worker = match @native.CaptureWorker::new() {
    Ok(value) => value
    Err(_) =>
      raise ResourceStartupFailure("TLS maintenance backend unavailable")
  }
  errdefer finish_tls_worker(worker)
  errdefer (for item in leases {
    let (_, lease) = item
    lease.release()
  })
  let mut task_id = 1L
  for source in hot.tls_sources {
    let cert = match
      bundle.material_bytes("mqtt_cert", listener_id=source.listener_id) {
      Some(value) => value
      None => raise ResourceStartupFailure("bundle TLS certificate missing")
    }
    let key = match
      bundle.material_bytes("mqtt_key", listener_id=source.listener_id) {
      Some(value) => value
      None => raise ResourceStartupFailure("bundle TLS key missing")
    }
    let size = cert.length().to_int64() + key.length().to_int64()
    let cost = size * 3L + 4096L
    let ticket = match pool.reserve(cost) {
      Ok(value) => value
      Err(_) => raise ResourceStartupFailure("TLS generation budget exceeded")
    }
    ticket.commit().unwrap()
    let mut moved = false
    errdefer (if !moved { ticket.release().unwrap() })
    let timeout = hot.listener_topology.filter(listener => {
        listener.id == source.listener_id
      })[0].tls_handshake_timeout_ms
    let original = TlsServerConfig::new(
      source.cert_path,
      source.key_path,
      handshake_timeout_ms=timeout,
    ).unwrap()
    let lease = prepare_tls_lease(worker, task_id, original, cert, key, ticket)
    validate_tls_config(lease.config) catch {
      _ => {
        lease.release()
        moved = true
        raise ResourceStartupFailure("TLS prepared handshake failed")
      }
    }
    leases.push((source.listener_id, lease))
    moved = true
    task_id += 1L
  }
  finish_tls_worker(worker)
  { leases, transferred: false }
}
