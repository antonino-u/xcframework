//
//  XCFrameworkBuilder.swift
//  XCFrameworkKit
//
//  Created by Jeff Lett on 6/8/19.
//

import Foundation
import Shell
import Files

public class XCFrameworkBuilder {
    public var name: String?
    public var project: String?
    public var outputDirectory: String?
    public var buildDirectory: String?
    public var iOSScheme: String?
    public var watchOSScheme: String?
    public var tvOSScheme: String?
    public var macOSScheme: String?
    public var verbose: Bool = false
    public var keepArchives: Bool = false
    public var compilerArguments: [String]?
    
    public enum XCFrameworkError: Error {
        case name
        case projectNotFound
        case noSchemesFound
        case buildDirectoryNotFound
        case outputDirectoryNotFound
        case buildError(String)
        
        public var description: String {
            switch self {
            case .name:
                return "Name is required when more than one scheme is provided."
            case .projectNotFound:
                return "No project parameter found."
            case .noSchemesFound:
                return "No schemes found."
            case .buildDirectoryNotFound:
                return "No build directory found."
            case .outputDirectoryNotFound:
                return "No output directory found."
            case .buildError(let stderr):
                return stderr
            }
        }
    }
    
    private enum SDK: String {
        case iOS = "iphoneos"
        case watchOS = "watchos"
        case tvOS = "appletvos"
        case macOS = "macosx"
        case iOSSim = "iphonesimulator"
        case watchOSSim = "watchsimulator"
        case tvOSSim = "appletvsimulator"
    }
    
    public static let archiveInstallPath = "All"
    
    public init(configure: (XCFrameworkBuilder) -> ()) {
        configure(self)
    }
    
    public func build() -> Result<[Archive],XCFrameworkError> {
                
        guard let project = project else {
            return .failure(XCFrameworkError.projectNotFound)
        }
                
        guard let outputDirectory = outputDirectory else {
            return .failure(XCFrameworkError.outputDirectoryNotFound)
        }
        
        guard let buildDirectory = buildDirectory else {
            return .failure(XCFrameworkError.buildDirectoryNotFound)
        }
        
        //if there are multiple schemes, then the name parameter is required. Otherwise, use the one specified scheme.
        let schemes = [watchOSScheme, iOSScheme, macOSScheme, tvOSScheme].compactMap({$0})
        if schemes.count == 0 {
            return .failure(XCFrameworkError.noSchemesFound)
        } else if schemes.count > 1 && self.name == nil {
            return .failure(XCFrameworkError.name)
        }
        let name = self.name ?? schemes[0]

        print("Building schemes...")
        
        //final build location
        let finalBuildDirectory = buildDirectory.hasSuffix("/") ? buildDirectory : buildDirectory + "/"
        
        //final xcframework location
        let finalOutputDirectory = outputDirectory.hasSuffix("/") ? outputDirectory : outputDirectory + "/"
        
        var archives = [Archive]()
        
        //try all supported SDKs
        do {
            if let watchOSScheme = watchOSScheme {
                try archives.append(buildScheme(scheme: watchOSScheme, sdk: .watchOS, project: project, buildPath: finalBuildDirectory))
                try archives.append(buildScheme(scheme: watchOSScheme, sdk: .watchOSSim, project: project, buildPath: finalBuildDirectory))
            }
            
            if let iOSScheme = iOSScheme {
                try archives.append(buildScheme(scheme: iOSScheme, sdk: .iOS, project: project, buildPath: finalBuildDirectory))
                try archives.append(buildScheme(scheme: iOSScheme, sdk: .iOSSim, project: project, buildPath: finalBuildDirectory))
            }
            
            if let tvOSScheme = tvOSScheme {
                try archives.append(buildScheme(scheme: tvOSScheme, sdk: .tvOS, project: project, buildPath: finalBuildDirectory))
                try archives.append(buildScheme(scheme: tvOSScheme, sdk: .tvOSSim, project: project, buildPath: finalBuildDirectory))
            }
            
            if let macOSScheme = macOSScheme {
                try archives.append(buildScheme(scheme: macOSScheme, sdk: .macOS, project: project, buildPath: finalBuildDirectory))
            }
        } catch let error as XCFrameworkError {
            return .failure(error)
        } catch {
            return .failure(.buildError(error.localizedDescription))
        }
        
        print("Combining...")
        
        //An archive command may produce multiple different frameworks, so we need to map them by their names and create an xcframework per generated framework
        let allFrameworks = archives.flatMap({ $0.frameworks })
        typealias OrganizedFrameworks = [String : [Framework]]
        let organizedFrameworks = allFrameworks.reduce(OrganizedFrameworks(), { (result, framework) -> OrganizedFrameworks in
            var result = result
            var array: [Framework]
            if let existingArray = result[framework.name] {
                array = existingArray
                array.append(framework)
            } else {
                array = [framework]
            }
            result[framework.name] = array
            return result
        })
        
        var overriddenName: String?
        if organizedFrameworks.count == 1 {
            overriddenName = name
        }
        
        for (frameworkName, frameworks) in organizedFrameworks {
            
            let name = overriddenName ?? frameworkName
            
            let finalOutput = finalOutputDirectory + name + ".xcframework"
            try? Folder(path: finalOutput).delete()

            print("Creating \(name).xcframework")
            
            var arguments = ["-create-xcframework"]
            for framework in frameworks {
                arguments.append(contentsOf: ["-framework", framework.path])
            }
            arguments.append("-output")
            arguments.append(finalOutput)
            if verbose {
                print("xcodebuild \(arguments.joined(separator: " "))")
            }
            let result = shell.usr.bin.xcodebuild.dynamicallyCall(withArguments: arguments)
            if !result.isSuccess {
                return .failure(.buildError(result.stderr + "\nXCFramework Build Error From Running: 'xcodebuild \(arguments.joined(separator: " "))'"))
            }
            print("Created \(name).xcframework")
        }
        
        if self.keepArchives {
            print("Keeping generated archives.")
        } else {
            print("Cleaning up...")
            try? Folder(path: buildDirectory).delete()
        }
        
        return .success(archives)
    }
    
    private func buildScheme(scheme: String, sdk: SDK, project: String, buildPath: String) throws -> Archive {
        print("Building scheme \(scheme) for \(sdk.rawValue)...")
        //path for each scheme's archive
        let archivePath = buildPath + "\(scheme)-\(sdk.rawValue).xcarchive"
        //array of arguments for the archive of each framework
        //weird interpolation errors are forcing me to use this "" + syntax.  not sure if this is a compiler bug or not.
        var archiveArguments = ["-project", "\"" + project + "\"", "-scheme", "\"" + scheme + "\"", "archive", "SKIP_INSTALL=NO", "BUILD_LIBRARY_FOR_DISTRIBUTION=YES", "INSTALL_PATH=\"\(XCFrameworkBuilder.archiveInstallPath)\""]
        if let compilerArguments = compilerArguments {
            archiveArguments.append(contentsOf: compilerArguments)
        }
        archiveArguments.append(contentsOf: ["-archivePath", archivePath, "-sdk", sdk.rawValue])
        if verbose {
            print("   xcodebuild \(archiveArguments.joined(separator: " "))")
        }
        let result = shell.usr.bin.xcodebuild.dynamicallyCall(withArguments: archiveArguments)
        if !result.isSuccess || !result.stderr.isEmpty {
            let errorMessage = result.stderr + "\nArchive Error From Running: 'xcodebuild \(archiveArguments.joined(separator: " "))'"
            throw XCFrameworkError.buildError(errorMessage)
        }
        
        var frameworks = [Framework]()
        let generatedFrameworksPath = archivePath + "/Products/" + XCFrameworkBuilder.archiveInstallPath
        do {
            let generatedFrameworksFolder = try Folder(path: generatedFrameworksPath)
            for subfolder in generatedFrameworksFolder.subfolders {
                if subfolder.name.hasSuffix(Framework.extension) {
                    frameworks.append(Framework(path: subfolder.path, name: subfolder.nameExcludingExtension, archs: [sdk.rawValue], temporary: true))
                }
            }
        } catch let error {
            throw XCFrameworkError.buildError(error.localizedDescription)
        }
        return Archive(path: archivePath, frameworks: frameworks)
    }
}
