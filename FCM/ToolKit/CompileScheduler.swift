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

// MARK: - 内存信息

struct MemoryInfo {
    var total: UInt64
    var free: UInt64

    var totalMB: Int { return Int(total / 1024 / 1024) }
    var freeMB: Int { return Int(free / 1024 / 1024) }
}

/// 读取设备内存（iOS 上使用 host_statistics64，失败时退回保守值）
func currentMemoryInfo() -> MemoryInfo {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)

    // 物理内存总量：sysctl hw.memsize
    var total: UInt64 = 0
    var size = MemoryLayout<UInt64>.size
    if sysctlbyname("hw.memsize", &total, &size, nil, 0) != 0 {
        total = 2 * 1024 * 1024 * 1024   // 无法读取时按 2GB 保守估计
    }

    // 当前进程可用量：用 task_info 的 resident_size 做粗估，
    // 真正可用的空闲内存 iOS 不直接暴露，这里按总内存的 35% 估算上限。
    let taskResult = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    _ = taskResult

    // iOS 会为系统与前台 App 保留大量内存，编译只能用到其中一部分。
    // 经验值：总内存的 25%，再扣掉 512MB 固定余量（避免刚好卡在边界）。
    var available = total * 30 / 100
    let reserve: UInt64 = 384 * 1024 * 1024
    available = available > reserve ? available - reserve : available / 2
    return MemoryInfo(total: total, free: available)
}

// MARK: - 调度策略

struct CompileScheduler {
    var parallelism: Int          // 同时运行的编译进程数
    var batchSize: Int            // 每批处理的文件数
    var reason: String            // 决策依据（写进日志）

    /// 单个 clang 进程处理一个 .m 的预估常驻内存
    // 实测经验值：clang -fmodules 时单个进程常驻 150~250MB，
    // 取 200MB 作为中位估计（过大导致并行度过低，过小容易被 jetsam）。
    static let estimatedMemoryPerJob: UInt64 = 200 * 1024 * 1024

    static func make(projectPath: String, fileCount: Int) -> CompileScheduler {
        let mem = currentMemoryInfo()
        let cores = ProcessInfo.processInfo.activeProcessorCount

        // 并行度 = min(CPU 核数, 可用内存 / 单进程预估)
        var byMemory = Int(mem.free / estimatedMemoryPerJob)
        if byMemory < 1 { byMemory = 1 }

        var parallelism = min(cores, byMemory)
        // 上限 6：再多收益很小，内存风险陡增
        if parallelism > 6 { parallelism = 6 }
        if parallelism < 1 { parallelism = 1 }

        var batchSize = 0
        if fileCount <= 40 {
            // 小工程：一次跑完，省掉批间开销
            batchSize = fileCount
            parallelism = min(parallelism, max(1, fileCount))
        } else {
            // 大工程：分批，每批不超过 并行度 × 8，给系统留出回收窗口
            batchSize = parallelism * 8
        }

        let reason = "内存 \(mem.totalMB)MB（可用约 \(mem.freeMB)MB），CPU \(cores) 核"
            + " → 并行 \(parallelism)，每批 \(batchSize) 个"

        return CompileScheduler(parallelism: parallelism,
                                batchSize: batchSize,
                                reason: reason)
    }
}
