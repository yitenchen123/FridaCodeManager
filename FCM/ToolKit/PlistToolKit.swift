 /* 
 PlistToolkit.swift 

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

/// 读取 plist（统一走 PropertyListSerialization，避免已废弃的 NSDictionary 构造器）
func readPlistDictionary(at path: String) -> [String: Any]? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil))
        as? [String: Any]
}

/// 原子写入 XML plist
@discardableResult
func writePlistDictionary(_ dictionary: [String: Any], to path: String) -> Bool {
    do {
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary,
                                                      format: .xml,
                                                      options: 0)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        return true
    } catch {
        print("Error writing plist: \(error)")
        return false
    }
}

func rplist(forKey key: String, plistPath: String) -> String? {
    guard let plistDict = readPlistDictionary(at: plistPath) else {
        print("Error reading plist file at \(plistPath)")
        return nil
    }
    
    guard let value = plistDict[key] as? String else {
        print("Value not found for key '\(key)' in plist file at \(plistPath)")
        return nil
    }
    
    return value
}

func wplist(value: Any, forKey key: String, plistPath: String) -> Int {
    var plistDict = readPlistDictionary(at: plistPath) ?? [:]
    plistDict[key] = value
    
    if writePlistDictionary(plistDict, to: plistPath) {
        print("Value successfully written to \(plistPath) for key: \(key)")
    } else {
        print("Error writing value to \(plistPath) for key: \(key)")
        return 1
    }
    return 0
}

func paeplist(aname arrayName: String, path plistPath: String) -> Bool {
    guard let plistData = FileManager.default.contents(atPath: plistPath),
          let plistDictionary = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
          let _ = plistDictionary[arrayName] as? [Any] else {
        return false
    }
    
    return true
}

func caplist(aname arrayName: String, path plistPath: String, arrayData: [Any]) -> Int {
    var plistDictionary = (try? PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: plistPath)), options: [], format: nil) as? [String: Any]) ?? [:]
    
    plistDictionary[arrayName] = arrayData
    
    do {
        let updatedPlistData = try PropertyListSerialization.data(fromPropertyList: plistDictionary, format: .xml, options: 0)
        try updatedPlistData.write(to: URL(fileURLWithPath: plistPath))
        print("Array '\(arrayName)' created successfully in plist file at '\(plistPath)'.")
    } catch {
        print("Error writing to plist file: \(error)")
        return 1
    }
    return 0
}

func rmaplist(aname arrayName: String, path plistPath: String) -> Int {
    guard var plistDictionary = try? PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: plistPath)), options: [], format: nil) as? [String: Any] else {
        print("Error reading plist file at \(plistPath)")
        return 2
    }
    
    plistDictionary.removeValue(forKey: arrayName)
    
    do {
        let updatedPlistData = try PropertyListSerialization.data(fromPropertyList: plistDictionary, format: .xml, options: 0)
        try updatedPlistData.write(to: URL(fileURLWithPath: plistPath))
        print("Array '\(arrayName)' removed successfully from plist file at '\(plistPath)'.")
    } catch {
        print("Error writing to plist file: \(error)")
        return 1
    }
    return 0
}

func aiaplist(item: Any, aname arrayName: String, path plistPath: String) -> Int {
    guard var plistDictionary = try? PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: plistPath)), options: [], format: nil) as? [String: Any],
          var targetArray = plistDictionary[arrayName] as? [Any] else {
        print("Error reading or finding array '\(arrayName)' in plist file at \(plistPath)")
        return 2
    }
    
    targetArray.append(item)
    plistDictionary[arrayName] = targetArray
    
    do {
        let updatedPlistData = try PropertyListSerialization.data(fromPropertyList: plistDictionary, format: .xml, options: 0)
        try updatedPlistData.write(to: URL(fileURLWithPath: plistPath))
        print("Item '\(item)' added successfully to array '\(arrayName)' in plist file at '\(plistPath)'.")
    } catch {
        print("Error writing to plist file: \(error)")
        return 1
    }
    return 0
}

func rmplist(key: String, plistPath: String) -> Int {
    guard var dict = readPlistDictionary(at: plistPath) else {
        print("Error: Unable to load plist file at \(plistPath)")
        return 2
    }

    dict.removeValue(forKey: key)
    
    if writePlistDictionary(dict, to: plistPath) {
        print("Key '\(key)' deleted successfully from \(plistPath)")
    } else {
        print("Error: Unable to write changes to \(plistPath)")
        return 1
    }
    return 0
}
