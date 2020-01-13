//
//  File.swift
//  
//
//  Created by Antonino Urbano on 2020-01-12.
//

import Foundation

public struct Framework {
    
    public static let `extension` = ".framework"

    public let path: String
    public let name: String
    public let archs: [String]
    public let temporary: Bool
    
    var binaryPath: String {
        path+"/"+name
    }
}
