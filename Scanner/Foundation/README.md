# FoundationScanner

M1 adapter выполняет shallow `FileManager.contentsOfDirectory` вызовы на utility `DispatchQueue` и читает metadata через `lstat`. Он records-only для symbolic links, не пересекает `st_dev` root volume и передаёт transient records единственному `ScanCoordinator` owner. Foundation возвращает весь array одного directory read; wide-directory peak memory измеряется benchmark harness, а не выдаётся за fixed-size batch.
