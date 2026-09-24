///|
async fn wait_capture(worker : CaptureWorker) -> Int64 {
  for _ in 0..<1000 {
    if worker.poll() is Some(id) {
      return id
    }
    @async.sleep(1)
  }
  abort("native capture worker did not finish")
}

///|
async fn stop_capture(worker : CaptureWorker) -> Unit {
  for _ in 0..<1000 {
    if worker.stop() {
      assert_true(worker.destroy())
      return
    }
    @async.sleep(1)
  }
  abort("native capture worker did not stop")
}

///|
async test "capture worker hashes and copies a bounded file" {
  let root = @fs.tmpdir(prefix="mqtt-capture-worker-")
  let path = root + "/source"
  @fs.write_file(path, b"abc", create_mode=CreateNew, permission=0o600)
  let worker = CaptureWorker::new().unwrap()
  assert_eq(worker.submit(1L, path, 1048576), Ok(()))
  assert_eq(wait_capture(worker), 1L)
  let (length, digest) = worker.result_info(1L).unwrap()
  assert_eq(length, 3)
  assert_eq(
    digest,
    Bytes::from_array([
      0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea, 0x41, 0x41, 0x40, 0xde, 0x5d,
      0xae, 0x22, 0x23, 0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c, 0xb4, 0x10,
      0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
    ]),
  )
  assert_eq(worker.copy_chunk(1L, 0), Ok(b"abc"))
  assert_eq(worker.copy_chunk(1L, 3), Ok(b""))
  assert_eq(worker.submit(2L, path, 1048576), Err(Busy))
  assert_eq(worker.reap(1L), Ok(()))
  @fs.remove(path)
  let payload : Array[Byte] = []
  for _ in 0..<5000 {
    payload.push(65)
  }
  @fs.write_file(
    path,
    Bytes::from_array(payload),
    create_mode=CreateNew,
    permission=0o600,
  )
  assert_eq(worker.submit(2L, path, 1048576), Ok(()))
  assert_eq(wait_capture(worker), 2L)
  assert_eq(worker.result_info(2L).unwrap().0, 5000)
  assert_eq(worker.copy_chunk(2L, 0).unwrap().length(), 4096)
  assert_eq(worker.copy_chunk(2L, 4096).unwrap().length(), 904)
  assert_eq(worker.reap(2L), Ok(()))
  stop_capture(worker)
  @fs.remove(path)
  @fs.rmdir(root)
}

///|
async test "capture worker rejects unsafe and oversized sources" {
  let root = @fs.tmpdir(prefix="mqtt-capture-reject-")
  let path = root + "/source"
  let link = root + "/link"
  @fs.write_file(path, b"abc", create_mode=CreateNew, permission=0o644)
  @fs.symlink(target="source", link)
  let worker = CaptureWorker::new().unwrap()
  assert_eq(worker.submit(1L, link, 1024), Ok(()))
  assert_eq(wait_capture(worker), 1L)
  assert_eq(worker.result_info(1L), Err(UnsafeSource))
  assert_eq(worker.reap(1L), Ok(()))
  assert_eq(worker.submit(2L, path, 1024, private_file=true), Ok(()))
  assert_eq(wait_capture(worker), 2L)
  assert_eq(worker.result_info(2L), Err(UnsafeSource))
  assert_eq(worker.reap(2L), Ok(()))
  assert_eq(worker.submit(3L, path, 2), Ok(()))
  assert_eq(wait_capture(worker), 3L)
  assert_eq(worker.result_info(3L), Err(TooLarge))
  assert_eq(worker.reap(3L), Ok(()))
  stop_capture(worker)
  @fs.remove(link)
  @fs.remove(path)
  @fs.rmdir(root)
}

///|
async test "TLS native worker validates and owns material until transfer" {
  let fixture = @fs.tmpdir(prefix="mqtt-native-tls-")
  let cert = fixture + "/server.crt"
  let key = fixture + "/server.key"
  let other_key = fixture + "/other.key"
  let other_cert = fixture + "/other.crt"
  let (status, _, _) = @process.collect_output("openssl", [
    "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-nodes", "-days", "1", "-subj",
    "/CN=localhost", "-keyout", key, "-out", cert,
  ])
  assert_eq(status, 0)
  let (other_status, _, _) = @process.collect_output("openssl", [
    "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-nodes", "-days", "1", "-subj",
    "/CN=localhost", "-keyout", other_key, "-out", other_cert,
  ])
  assert_eq(other_status, 0)
  @fs.chmod(key, 0o600)
  @fs.chmod(other_key, 0o600)
  let cert_bytes = @fs.read_file(cert).binary()
  let key_bytes = @fs.read_file(key).binary()
  let worker = CaptureWorker::new().unwrap()
  assert_eq(worker.submit_tls(1L, cert_bytes, key_bytes), Ok(()))
  assert_eq(wait_capture(worker), 1L)
  let directory = worker.take_tls_directory(1L).unwrap()
  assert_eq(@fs.read_file(directory + "/cert.pem").binary(), cert_bytes)
  assert_eq(@fs.read_file(directory + "/key.pem").binary(), key_bytes)
  assert_eq(worker.reap(1L), Ok(()))
  assert_true(@fs.exists(directory))
  @fs.remove(directory + "/cert.pem")
  @fs.remove(directory + "/key.pem")
  @fs.rmdir(directory)
  assert_eq(worker.submit_tls(2L, cert_bytes, key_bytes), Ok(()))
  assert_eq(wait_capture(worker), 2L)
  let (length, _) = worker.result_info(2L).unwrap()
  let unpublished = @utf8.decode(worker.copy_chunk(2L, 0).unwrap())
  assert_eq(unpublished.length(), length)
  assert_true(@fs.exists(unpublished))
  assert_eq(worker.reap(2L), Ok(()))
  assert_false(@fs.exists(unpublished))
  assert_eq(
    worker.submit_tls(3L, cert_bytes, @fs.read_file(other_key).binary()),
    Ok(()),
  )
  assert_eq(wait_capture(worker), 3L)
  assert_eq(worker.result_info(3L), Err(TlsInvalid))
  assert_eq(worker.reap(3L), Ok(()))
  let unsafe_root = fixture + "/unsafe"
  @fs.mkdir(unsafe_root, permission=0o755)
  assert_eq(
    worker.submit_tls(4L, cert_bytes, key_bytes, runtime_root=unsafe_root),
    Ok(()),
  )
  assert_eq(wait_capture(worker), 4L)
  assert_eq(worker.result_info(4L), Err(UnsafeSource))
  assert_eq(worker.reap(4L), Ok(()))
  let safe_root = fixture + "/safe"
  @fs.mkdir(safe_root, permission=0o700)
  let link = fixture + "/link"
  @fs.symlink(target="safe", link)
  assert_eq(
    worker.submit_tls(5L, cert_bytes, key_bytes, runtime_root=link),
    Ok(()),
  )
  assert_eq(wait_capture(worker), 5L)
  assert_eq(worker.result_info(5L), Err(UnsafeSource))
  assert_eq(worker.reap(5L), Ok(()))
  stop_capture(worker)
  @fs.rmdir(fixture, recursive=true)
}

///|
test "reload SHA256 matches the independent abc vector" {
  assert_eq(
    sha256(b"abc"),
    Ok(
      Bytes::from_array([
        0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea, 0x41, 0x41, 0x40, 0xde, 0x5d,
        0xae, 0x22, 0x23, 0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c, 0xb4, 0x10,
        0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
      ]),
    ),
  )
}
