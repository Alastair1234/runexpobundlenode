//
//  ContentView.swift
//  RunExpo
//
//  Created by Ayat on 31/12/24.
//

import SwiftUI
import WebKit

func chooseDir() -> String? {
    let op = NSOpenPanel()
    op.prompt = "Select"
    op.message = "Please select where to create expo project"
    op.allowedContentTypes = [.directory]
    op.canChooseFiles = false
    op.allowsOtherFileTypes = false
    op.allowsMultipleSelection = false
    op.canChooseDirectories = true
    op.canCreateDirectories = true
    
    let result = op.runModal()
    if result != .OK {
        print("User cancelled")
        return nil
    }
    
    if op.url!.absoluteString == "file:///" {
        print("User didn't select any directory")
        return nil
    }
    
    return op.url!.path
}

func extractBundledNode(nodePath: String) -> Bool {
    // check if target dir has node included
    if FileManager.default.fileExists(atPath: "\(nodePath)/bin/node") {
        print("Node.js already exists on target directory")
        return true
    }
    
    // get bundled node.js
    guard let nodeZipUrl = Bundle.main.url(forResource: "node", withExtension: "tar.gz") else {
        print("No bundled node found in app")
        return false
    }
    
    do {
        // create target dir
        if !FileManager.default.fileExists(atPath: nodePath) {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: nodePath), withIntermediateDirectories: true, attributes: nil)
        }
        
        print("Extracting nodejs bundle")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["--strip-components", "1", "-xzf", nodeZipUrl.path, "-C", nodePath]

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            print("Node.js bundle extracted")
            return true
        } else {
            print("Extraction failed: \(process.terminationStatus)")
            return false
        }
    } catch {
        print("Cannot extract Node.js bundle: \(error)")
        return false
    }
}

struct ContentView: View {
    @State private var outText = "Hello Upwork!"
    @State private var webViewURL: String?
    @State private var selectedProject: String?
    
    var body: some View {
        HStack {
            VStack {
                Image(systemName: "globe")
                    .imageScale(.large)
                    .foregroundColor(.accentColor)
                
                Text(outText)
                
                Button("Create Expo Project") {
                    createExpoProject()
                }
                .padding()
                
                Button("Load Previous Project") {
                    loadPreviousProject()
                }
                .padding()
            }
            .padding()
            
            if let url = webViewURL {
                PhoneFrameView {
                    WebView(url: url)
                }
                .frame(width: 375, height: 812)
            } else {
                Spacer()
            }
        }
    }
    
    func createExpoProject() {
        // get embedded bun binary
        guard let bunBin = Bundle.main.url(forResource: "bun", withExtension: nil) else {
            outText = "bun is not found"
            return
        }
        
        // choose directory for installing expo
        guard let targetDir = chooseDir() else {
            print("No directory selected")
            return
        }
        print("User chose: \(targetDir)")
        
        // prepare node
        let downloadDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path
        if !extractBundledNode(nodePath: downloadDir + "/node") {
            outText = "Cannot extract node"
            return
        }
        
        // prepare ENV for process
        let currentEnv = ProcessInfo.processInfo.environment
        let envPath = currentEnv["PATH"] ?? ""
        let newPath = "\(downloadDir)/node/bin:\(envPath)"
        
        // create task
        let createTask = Process()
        let createPipe = Pipe()
        createTask.standardOutput = createPipe
        createTask.environment = [
            "PATH": newPath
        ]
        createTask.executableURL = bunBin
        createTask.arguments = ["create", "expo", "--yes", "--no-install", targetDir]
        
        // install task
        let installTask = Process()
        let installPipe = Pipe()
        installTask.standardOutput = installPipe
        installTask.environment = [
            "PATH": newPath
        ]
        installTask.executableURL = bunBin
        installTask.arguments = ["install"]
        installTask.currentDirectoryURL = URL(fileURLWithPath: targetDir)
        
        do {
            // create expo project
            try createTask.run()
            outText = "Creating..."
            createTask.waitUntilExit()
            
            let createOutput = String(data: createPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
            print(createOutput)
            outText = createOutput
            
            // install packages
            try installTask.run()
            outText = "Installing packages..."
            installTask.waitUntilExit()
            
            let installOutput = String(data: installPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
            print(installOutput)
            outText = installOutput
            
            // Start the Expo development server
            let startTask = Process()
            let startPipe = Pipe()
            startTask.standardOutput = startPipe
            startTask.environment = [
                "PATH": newPath,
                "CI": "1",
                "BROWSER": "none"
            ]
            startTask.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            startTask.arguments = ["npx", "expo", "start", "--web", "--port", "8081"]
            startTask.currentDirectoryURL = URL(fileURLWithPath: targetDir)
            
            // Kill any existing process running on port 8081
            let killTask = Process()
            killTask.executableURL = URL(fileURLWithPath: "/bin/sh")
            killTask.arguments = ["-c", "lsof -ti tcp:8081 | xargs kill -9"]
            try killTask.run()
            killTask.waitUntilExit()
            
            try startTask.run()
            outText = "Starting Expo development server..."
            openProjectInWebView(startPipe)
        } catch {
            print("Error running command: \(error)")
            outText = "\(error)"
        }
    }
    
    func loadPreviousProject() {
        let op = NSOpenPanel()
        op.prompt = "Select"
        op.message = "Please select the directory of a previous Expo project"
        op.allowedContentTypes = [.directory]
        op.canChooseFiles = false
        op.allowsOtherFileTypes = false
        op.allowsMultipleSelection = false
        op.canChooseDirectories = true
        
        let result = op.runModal()
        if result == .OK {
            let projectDir = op.url!.path
            selectedProject = projectDir
            
            // Start the Expo development server for the selected project
            startExpoServer(forProject: projectDir)
        }
    }
    
    fileprivate func openProjectInWebView(_ startPipe: Pipe) {
        startPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            if let output = String(data: fileHandle.availableData, encoding: .utf8), !output.isEmpty {
                print(output)
                
                let pattern = "http://localhost:[0-9]+"
                
                if let regex = try? NSRegularExpression(pattern: pattern) {
                    if let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)) {
                        if let range = Range(match.range, in: output) {
                            let foundURL = String(output[range])
                            
                            webViewURL = foundURL
                        }
                    } else {
                        print("URL not found")
                    }
                } else {
                    print("Invalid regular expression")
                }
                
                print("All done")
            }
        }
    }
    
    func startExpoServer(forProject projectDir: String) {
        // prepare node
        let downloadDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path
        if !extractBundledNode(nodePath: downloadDir + "/node") {
            outText = "Cannot extract node"
            return
        }
        
        // prepare ENV for process
        let currentEnv = ProcessInfo.processInfo.environment
        let envPath = currentEnv["PATH"] ?? ""
        let newPath = "\(downloadDir)/node/bin:\(envPath)"
        
        // Start the Expo development server
        let startTask = Process()
        let startPipe = Pipe()
        startTask.standardOutput = startPipe
        startTask.environment = [
            "PATH": newPath,
            "CI": "1",
            "BROWSER": "none"
        ]
        startTask.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        startTask.arguments = ["npx", "expo", "start", "--web", "--port", "8081"]
        startTask.currentDirectoryURL = URL(fileURLWithPath: projectDir)
        
        // Kill any existing process running on port 8081
        let killTask = Process()
        killTask.executableURL = URL(fileURLWithPath: "/bin/sh")
        killTask.arguments = ["-c", "lsof -ti tcp:8081 | xargs kill -9"]
        try? killTask.run()
        killTask.waitUntilExit()
        
        do {
            try startTask.run()
            outText = "Starting Expo development server..."
            
            openProjectInWebView(startPipe)
        } catch {
            print("Error running command: \(error)")
            outText = "\(error)"
        }
    }
}

struct WebView: NSViewRepresentable {
    let url: String
    
    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.load(URLRequest(url: URL(string: url)!))
        return webView
    }
    
    func updateNSView(_ nsView: WKWebView, context: Context) {
        if let url = URL(string: self.url) {
            let request = URLRequest(url: url)
            nsView.load(request)
        }
    }
}

struct PhoneFrameView<Content: View>: View {
    let content: () -> Content
    
    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 40)
                .fill(Color.black)
            
            VStack {
                Spacer()
                    .frame(height: 20)
                
                HStack {
                    Spacer()
                        .frame(width: 20)
                    
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.black)
                        .frame(width: 160, height: 30)
                    
                    Spacer()
                        .frame(width: 20)
                }
                
                Spacer()
                    .frame(height: 10)
                
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .cornerRadius(30)
                    .padding(20)
                
                Spacer()
                    .frame(height: 20)
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
