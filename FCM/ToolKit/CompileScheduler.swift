/*
 CompileScheduler.swift

 This file is part of FridaCodeManager.

 FridaCodeManager is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 FridaCodeManager is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with FridaCodeManager. If not, see <https://www.gnu.org/licenses/>.

 编译调度：决定并行度与分批大小。

 手机编译大工程最大的风险不是慢，而是 jetsam（系统因内存压力杀进程）。
 每个 clang 进程处理一个 .m 大约占 40~120MB 常驻内存，
 200+ 个文件如果一次全并行，必然被杀。

 策略：
   1. 并行度按「可用内存 / 单进程预估内存」计算，而非只看 CPU 核数
   2. 分批（batch）执行，每批结束等待宿主回收内存
   3. 某一批出现异常退出（可能被 jetsam）时，自动降低并行度重试该批
 */

import Foundation
import Darwin

// MARK: - 内存信息

struct MemoryInfo {
    var total: UInt64
    var free: UInt64

    var totalMB: Int { return Int(total / 1024 / 1024) }
    var freeMB: Int { return Int(free / 1024 / 1024) }
}

/// 读取设备内存。
/// - 总量：sysctl hw.memsize
/// - 可用：host_statistics64 的空闲/非活跃/可回收页；读不到时退回总量的 30%
/// 这样 iPhone 7/8（2GB）与 iPhone X（3GB）能拿到真实余量，
/// 内存紧张时自动降到串行，余量充足时才提高并行度。
func currentMemoryInfo() -> MemoryInfo {
    // 物理内存总量：sysctl hw.memsize
    var total: UInt64 = 0
    var size = MemoryLayout<UInt64>.size
    if sysctlbyname("hw.memsize", &total, &size, nil, 0) != 0 {
        total = 2 * 1024 * 1024 * 1024   // 无法读取时按 2GB 保守估计
    }

    var pageSize: UInt64 = 16 * 1024
    var pageSizeLen = MemoryLayout<UInt64>.size
    sysctlbyname("hw.pagesize", &pageSize, &pageSizeLen, nil, 0)

    var stats = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size
        / MemoryLayout<integer_t>.size)
    let statsResult = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }

    var freeBytes = total * 30 / 100
    if statsResult == KERN_SUCCESS {
        let pages = UInt64(stats.free_count)
            + UInt64(stats.inactive_count)
            + UInt64(stats.speculative_count)
            + UInt64(stats.purgeable_count)
        freeBytes = pages * pageSize
    }

    // 系统视角之外，再看 jetsam 视角：os_proc_available_memory 返回
    // 「本进程在被杀之前还能拿到多少」。两者取小更安全 ——
    // 本进程自己接近上限时继续加并行，最先被杀的就是 App 本身。
    let appAvailable = processAvailableMemory()
    if appAvailable > 0 {
        freeBytes = min(freeBytes, appAvailable)
    }

    // 空闲页里也只有一部分能用来编译：系统会随时回收，留出安全边界。
    // 上限取总内存的 45%：再高就会把系统其它进程推到 jetsam 边缘。
    freeBytes = min(freeBytes * 3 / 4, total * 45 / 100)

    // 固定余量：给系统、UI 与前台 App 留出空间。
    // 2GB 机器留 160MB，避免刚好卡在 jetsam 边界。
    let reserve: UInt64 = 160 * 1024 * 1024
    let available = freeBytes > reserve ? freeBytes - reserve : freeBytes / 2
    return MemoryInfo(total: total, free: available)
}

/// 读取 os_proc_available_memory（iOS 13 起提供）。
/// 用 dlsym 动态查找而不是直接调用：老系统没有这个符号，
/// 直接引用会在启动时崩溃。返回 0 表示不可用。
private func processAvailableMemory() -> UInt64 {
    typealias AvailableMemoryFn = @convention(c) () -> UInt64
    guard let handle = dlopen(nil, RTLD_NOW),
          let symbol = dlsym(handle, "os_proc_available_memory") else { return 0 }
    let function = unsafeBitCast(symbol, to: AvailableMemoryFn.self)
    return function()
}

// MARK: - 调度策略

struct CompileScheduler {
    var parallelism: Int          // 同时运行的编译进程数
    var reason: String            // 决策依据（写进日志）

    /// 单个 clang 进程处理一个 .m / .c 的预估常驻内存。
    /// FCM 用 header map 而不是 -fmodules，单进程通常在 60~150MB；
    /// 取 120MB 作为中位估计，配合真实空闲内存计算并行度。
    static let estimatedMemoryPerJob: UInt64 = 120 * 1024 * 1024

    static func make(projectPath: String, fileCount: Int) -> CompileScheduler {
        let mem = currentMemoryInfo()
        let cores = ProcessInfo.processInfo.activeProcessorCount

        // 并行度 = min(CPU 核数, 可用内存 / 单进程预估)
        var byMemory = Int(mem.free / estimatedMemoryPerJob)
        if byMemory < 1 { byMemory = 1 }

        // 设备档位上限：先保证不被 jetsam，再追求速度。
        // 这些只是「天花板」，真正并行度仍由上面的可用内存计算决定：
        // 内存宽裕时用满档位，内存吃紧时自动回落到 1。
        // 2GB（iPhone 7/8）上限 3，3GB（iPhone X）上限 4，4~5GB 上限 5，
        // 6GB 上限 7，更大上限 8（再高收益很小，内存风险陡增）。
        let cap: Int
        if mem.total < 2400 * 1024 * 1024 {
            cap = 3
        } else if mem.total < 3300 * 1024 * 1024 {
            cap = 4
        } else if mem.total < 4400 * 1024 * 1024 {
            cap = 5
        } else if mem.total < 6600 * 1024 * 1024 {
            cap = 7
        } else {
            cap = 8
        }

        var parallelism = min(cores, byMemory, cap)
        if parallelism > 8 { parallelism = 8 }
        if parallelism < 1 { parallelism = 1 }

        // 小工程：并行度不超过文件数，避免空转的进程槽
        if fileCount <= 40 {
            parallelism = min(parallelism, max(1, fileCount))
        }

        let reason = "内存 \(mem.totalMB)MB（可用于编译约 \(mem.freeMB)MB），CPU \(cores) 核"
            + " → 并行 \(parallelism)（上限 \(cap)）"
        return CompileScheduler(parallelism: parallelism, reason: reason)
    }
}
