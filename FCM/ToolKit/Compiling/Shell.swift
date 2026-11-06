 /* 
 Shell.swift 

 Copyright (C) 2023, 2024 SparkleChan and SeanIsTethered 
 Copyright (C) 2024 fridakitten 

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

  ______    _     _         _____        __ _                           ______                    _       _   _
 |  ___|  (_)   | |       /  ___|      / _| |                          |  ___|                  | |     | | (_)
 | |_ _ __ _  __| | __ _  \ `--.  ___ | |_| |___      ____ _ _ __ ___  | |_ ___  _   _ _ __   __| | __ _| |_ _  ___  _ __
 |  _| '__| |/ _` |/ _` |  `--. \/ _ \|  _| __\ \ /\ / / _` | '__/ _ \ |  _/ _ \| | | | '_ \ / _` |/ _` | __| |/ _ \| '_ \
 | | | |  | | (_| | (_| | /\__/ / (_) | | | |_ \ V  V / (_| | | |  __/ | || (_) | |_| | | | | (_| | (_| | |_| | (_) | | | |
 \_| |_|  |_|\__,_|\__,_| \____/ \___/|_|  \__| \_/\_/ \__,_|_|  \___| \_| \___/ \__,_|_| |_|\__,_|\__,_|\__|_|\___/|_| |_|
 Founded by. Sean Boleslawski, Benjamin Hornbeck and Lucienne Salim in 2023
 */ 
    
import Foundation
import Darwin

/// waitpid 返回的是 wait status，不是退出码。
/// 直接把它当退出码会得到 256/512 之类的值，日志里的“退出码”全部失真。
func normalizedExitCode(_ status: Int32) -> Int {
    let signal = Int(status & 0x7f)
    if signal == 0 {
        return Int((status >> 8) & 0xff)
    }
    return 128 + signal
}

/// 一次受控执行的结局。
/// timedOut 表示是我们主动杀的，必须和「命令自己失败」区分开，
/// 否则用户只会看到一句莫名的退出码 137。
struct ShellOutcome {
    var code: Int
    var timedOut: Bool
    var reason: String
}

#if jailbreak || trollstore

// Define C functions
@_silgen_name("posix_spawnattr_set_persona_np")
func posix_spawnattr_set_persona_np(_ attr: UnsafeMutablePointer<posix_spawnattr_t?>, _ persona_id: uid_t, _ flags: UInt32)
@_silgen_name("posix_spawnattr_set_persona_uid_np")
func posix_spawnattr_set_persona_uid_np(_ attr: UnsafeMutablePointer<posix_spawnattr_t?>, _ persona_id: uid_t)
@_silgen_name("posix_spawnattr_set_persona_gid_np")
func posix_spawnattr_set_persona_gid_np(_ attr: UnsafeMutablePointer<posix_spawnattr_t?>, _ persona_id: uid_t)

#if jailbreak
private let shellExecutable = "/usr/bin/bash"
private func shellEnvironment(_ extra: [String]) -> [String] {
    return ["PATH=/usr/local/sbin:\(jbroot)/usr/local/sbin:/usr/local/bin:\(jbroot)/usr/local/bin:/usr/sbin:\(jbroot)/usr/sbin:/usr/bin:\(jbroot)/usr/bin:/sbin:\(jbroot)/sbin:/bin:\(jbroot)/bin:/usr/bin/X11:\(jbroot)/usr/bin/X11:/usr/games:\(jbroot)/usr/games","HOME=\(global_container)","TMPDIR=\(global_container)/tmp"] + extra
}
#else
private let shellExecutable = "/bin/dash"
private func shellEnvironment(_ extra: [String]) -> [String] {
    return ["PATH=/usr/local/sbin:\(jbroot)/bin","HOME=\(global_container)","TMPDIR=\(global_container)/tmp"] + extra
}
#endif

/// 启动进程并等待，支持「总时长」和「空闲」两种超时。
///
/// 关键点：子进程放进独立进程组。编译卡死时 xargs 还活着、clang 还挂着，
/// 只 kill(pid) 会留下一堆孤儿进程继续吃内存，必须 kill(-pid) 整组收掉。
///
/// - Parameter progress: 返回一个代表“任务还在推进”的数值（通常是日志文件大小）。
///   值不变的时间超过 idleTimeout 即判定卡死。
private func spawnAndWait(executable: String,
                          argv: [String],
                          uid: uid_t,
                          env: [String],
                          timeout: Int,
                          idleTimeout: Int,
                          progress: (() -> Int)?) -> ShellOutcome {
    var pid: pid_t = 0
    let args: [String] = [String(executable.split(separator: "/").last!)] + argv
    let argvPtr: [UnsafeMutablePointer<CChar>?] = args.map { $0.withCString(strdup) }
    defer { for case let pointer? in argvPtr { free(pointer) } }
    let envPtr: [UnsafeMutablePointer<CChar>?] = env.map { $0.withCString(strdup) }
    defer { for case let pointer? in envPtr { free(pointer) } }

    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    posix_spawnattr_set_persona_np(&attr, 99, 1)
    posix_spawnattr_set_persona_uid_np(&attr, uid)
    posix_spawnattr_set_persona_gid_np(&attr, uid)
    posix_spawnattr_setpgroup(&attr, 0)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))

    guard posix_spawn(&pid, executable, nil, &attr, argvPtr + [nil], envPtr + [nil]) == 0 else {
        print("Failed to spawn process")
        return ShellOutcome(code: -1, timedOut: false, reason: "")
    }

    var status: Int32 = 0
    // 没有超时要求时保持原行为：阻塞等待，零轮询开销。
    if timeout <= 0 && (idleTimeout <= 0 || progress == nil) {
        if waitpid(pid, &status, 0) == -1 {
            return ShellOutcome(code: -1, timedOut: false, reason: "")
        }
        return ShellOutcome(code: normalizedExitCode(status), timedOut: false, reason: "")
    }

    let started = Date()
    var lastSeen = progress?() ?? 0
    var lastChange = started

    while true {
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid {
            return ShellOutcome(code: normalizedExitCode(status), timedOut: false, reason: "")
        }
        if result == -1 {
            return ShellOutcome(code: -1, timedOut: false, reason: "")
        }
        usleep(250_000)

        let now = Date()
        if let probe = progress {
            let value = probe()
            if value != lastSeen {
                lastSeen = value
                lastChange = now
            }
        }
        if idleTimeout > 0, progress != nil,
           now.timeIntervalSince(lastChange) >= Double(idleTimeout) {
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
            _ = waitpid(pid, &status, 0)
            return ShellOutcome(code: 137, timedOut: true,
                                reason: "连续 \(idleTimeout) 秒没有任何新输出，判定为卡死并已终止")
        }
        if timeout > 0, now.timeIntervalSince(started) >= Double(timeout) {
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
            _ = waitpid(pid, &status, 0)
            return ShellOutcome(code: 137, timedOut: true,
                                reason: "运行超过 \(timeout) 秒仍未结束，已终止")
        }
    }
}

@discardableResult
func shell(_ command: String, uid: uid_t? = 501, env: [String]? = []) -> Int {
    return shellMonitored(command, uid: uid ?? 501, env: env ?? []).code
}

/// 带超时的执行入口。timeout / idleTimeout 都是 0 时与 shell() 完全等价。
func shellMonitored(_ command: String, uid: uid_t = 501, env: [String] = [],
                    timeout: Int = 0, idleTimeout: Int = 0,
                    progress: (() -> Int)? = nil) -> ShellOutcome {
    return spawnAndWait(executable: jbroot + shellExecutable,
                        argv: ["-e", "-c", command],
                        uid: uid,
                        env: shellEnvironment(env),
                        timeout: timeout,
                        idleTimeout: idleTimeout,
                        progress: progress)
}

func runCommand(_ command: String, _ args: [String], _ uid: uid_t,_ env: [String]) -> Int {
    return spawnAndWait(executable: jbroot + command,
                        argv: args,
                        uid: uid,
                        env: shellEnvironment(env),
                        timeout: 0,
                        idleTimeout: 0,
                        progress: nil).code
}
#elseif stock
@discardableResult func shell(_ command: String, uid: uid_t? = 501, env: [String]? = []) -> Int {
    return 1
}

/// stock 版本没有真正的 shell，保留同签名以便上层代码不带条件编译。
func shellMonitored(_ command: String, uid: uid_t = 501, env: [String] = [],
                    timeout: Int = 0, idleTimeout: Int = 0,
                    progress: (() -> Int)? = nil) -> ShellOutcome {
    return ShellOutcome(code: 1, timedOut: false, reason: "")
}
#endif
