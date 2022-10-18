/**
    Shell.swift
    ShellKit
 
    Created by Tibor Bödecs on 2018.12.31.
    Copyright Binary Birds. All rights reserved.
 */

import Foundation
import Dispatch
import Combine
import NSTry

#if os(macOS)
private extension FileHandle {

    // checks if the FileHandle is a standard one (STDOUT, STDIN, STDERR)
    var isStandard: Bool {
        return self === FileHandle.standardOutput ||
            self === FileHandle.standardError ||
            self === FileHandle.standardInput
    }
}

// shell data handler protocol
public protocol ShellDataHandler {
    
    // called each time there is new data available
    func handle(_ data: Data)
    
    // optional method called on the end of the execution process
    func end()
}

public extension ShellDataHandler {

    func end() {
        // default implementation: do nothing...
    }
}

extension FileHandle: ShellDataHandler {

    public func handle(_ data: Data) {
        self.write(data)
    }

    public func end() {
        guard !self.isStandard else {
            return
        }
        self.closeFile()
    }
}
#endif

// a custom shell representation object
open class Shell {
    
    // shell errors
    public enum Error: LocalizedError {
        // invalid shell output data error
        case outputData
        // generic shell error, the first parameter is the error code, the second is the error message
        case generic(Int, String)
        // Objective-C error thrown during shell execution
        case nserror(Swift.Error)
        
        public var errorDescription: String? {
            switch self {
            case .outputData:
                return "Invalid or empty shell output."
            case .generic(let code, let message):
                return message + " (code: \(code))"
            case .nserror(let error):
                return "Internal error running process: \(error.localizedDescription)"
            }
        }
    }
    
    // lock queue to keep data writes in sync
    private let lockQueue: DispatchQueue

    // type of the shell, by default: /bin/sh
    public var type: String
    
    // custom env variables exposed for the shell
    public var env: [String: String]

    #if os(macOS)
    // output data handler
    public var outputHandler: ShellDataHandler?

    // error data handler
    public var errorHandler: ShellDataHandler?
    #endif

    /**
        Initializes a new Shell object
     
        - Parameters:
            - type: The type of the shell, default: /bin/sh
        - env: Additional environment variables for the shell, default: empty
     
     */
    public init(_ type: String = "/bin/sh", env: [String: String] = [:]) {
        self.lockQueue = DispatchQueue(label: "shellkit.lock.queue")
        self.type = type
        self.env = env
    }

    private var currentProcess: Process?
    private var isLaunched = false
    
    public func terminate() {
        if let process = currentProcess, isLaunched {
            process.terminate()
        }
    }
    
    /**
        Runs a specific command through the current shell.
     
        - Parameters:
            - command: The command to be executed
            - timeout: A timeout (in seconds) to apply to the command. If the timeout is triggered, the command is terminated.

        - Throws:
            `Shell.Error.outputData` if the command execution succeeded but the output is empty,
            otherwise `Shell.Error.generic(Int, String)` where the first parameter is the exit code,
            the second is the error message
     
        - Returns: The output string of the command without trailing newlines
     */
    @discardableResult
    public func run(_ command: String, timeout: TimeInterval? = nil) throws -> String {
        let process = Process()
        currentProcess = process
        
        process.launchPath = self.type
        process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment

        self.env.forEach { variable in
            process.environment?[variable.key] = variable.value
        }

        // Ensure that OS_ACTIVITY_DT_MODE is not passed as an environment key
        // Action copied from https://stackoverflow.com/questions/67595371/swift-package-calling-usr-bin-swift-errors-with-failed-to-open-macho-file-to
        // which was also suffering 'macho' symbolic link level messages
        process.environment?["OS_ACTIVITY_DT_MODE"] = nil

        var outputData = Data()
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
            
        var errorData = Data()
        let errorPipe = Pipe()
        process.standardError = errorPipe
            
        #if os(macOS)
        outputPipe.fileHandleForReading.readabilityHandler = { handler in
            let data = handler.availableData
            self.lockQueue.async {
                outputData.append(data)
                self.outputHandler?.handle(data)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handler in
            let data = handler.availableData
            self.lockQueue.async {
                errorData.append(data)
                self.errorHandler?.handle(data)
            }
        }
        #endif
                 
        // Catch Objective-C exceptions thrown when trying to start the process
        var caughtNSError: Swift.Error?
        do {
            try NSTry.catchException {
                process.launch()
                self.isLaunched = true
            }
        } catch {
            print("NSTry error detected", "process.launch()", error.localizedDescription)
            caughtNSError = error
        }
        
        
        #if os(macOS)
        var timeoutHandler: AnyCancellable?
        if isLaunched, let timeout = timeout, timeout > 0 {
            let processStart = Date.init()
            timeoutHandler = Timer.TimerPublisher(interval: 60, runLoop: .main, mode: .common)
                .autoconnect()
                .sink { publishedTime in
                    let now = publishedTime as Date
                    let duration = now.timeIntervalSince(processStart)
                    if duration > timeout {
                        _ = timeoutHandler
                        timeoutHandler = nil

                        print("Timeout (process running for \(Int(duration))s with timeout of \(Int(timeout))s)")
                        
                        // We're post-launch. We can call this even if the process has terminated.
                        process.terminate()
                    }
                }
        }
        #endif

        #if os(Linux)
        if isLaunched {
            self.lockQueue.sync {
                outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            }
        }
        #endif
        
        if isLaunched {
            do {
                try NSTry.catchException {
                    process.waitUntilExit()
                }
            } catch {
                print("NSTry error detected", "process.waitUntilExit()", error.localizedDescription)
                
                caughtNSError = error
            }
        }

        #if os(macOS)
        timeoutHandler?.cancel()
        timeoutHandler = nil
        #endif
        
        #if os(macOS)
        self.outputHandler?.end()
        self.errorHandler?.end()

        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        #endif
        
        var terminationStatus: Int32 = -1
        do {
            try NSTry.catchException {
                terminationStatus = process.terminationStatus
            }
        } catch {
            print("NSTry error detected", "process.terminationStatus", error.localizedDescription)
            
            caughtNSError = error
        }
        
        return try self.lockQueue.sync {
            defer {
                self.currentProcess = nil
                self.isLaunched = false
            }
            if let caughtNSError = caughtNSError {
                throw Error.nserror(caughtNSError)
            }
            guard terminationStatus == 0 else {
                var message = "Unknown error"
                if let error = String(data: errorData, encoding: .utf8) {
                    message = error.trimmingCharacters(in: .newlines)
                }
                throw Error.generic(Int(terminationStatus), message)
            }
            guard let output = String(data: outputData, encoding: .utf8) else {
                throw Error.outputData
            }
            return output.trimmingCharacters(in: .newlines)
        }
    }
    
    /**
        Async version of the run command
     
        - Parameters:
            - command: The command to be executed
            - timeout: A timeout (in seconds) to apply to the command. If the timeout is triggered, the command is terminated.
            - completion: The completion block with the output and error

        The command will be executed on a concurrent dispatch queue.
     */
    public func run(_ command: String, timeout: TimeInterval? = nil, completion: @escaping ((String?, Swift.Error?) -> Void)) {
        let queue = DispatchQueue(label: "shellkit.process.queue", attributes: .concurrent)
        queue.async {
            do {
                let output = try self.run(command, timeout: timeout)
                completion(output, nil)
            }
            catch {
                completion(nil, error)
            }
        }
    }
}
