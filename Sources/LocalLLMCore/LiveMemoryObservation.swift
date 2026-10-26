import Foundation

public enum LiveMemoryObservation {
    public static func read() -> MemoryObservation {
        let process = Process(); process.executableURL = URL(filePath: "/usr/bin/vm_stat")
        let pipe = Pipe(); process.standardOutput = pipe
        let physical = Int64(ProcessInfo.processInfo.physicalMemory)
        guard (try? process.run()) != nil else { return MemoryObservation(availableBytes: nil, physicalBytes: physical) }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
            return MemoryObservation(availableBytes: nil, physicalBytes: physical)
        }
        return MemoryObservation(availableBytes: MemoryObservation.availableBytes(fromVMStat: text), physicalBytes: physical)
    }
}
