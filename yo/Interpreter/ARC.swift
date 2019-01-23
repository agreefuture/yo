//
//  ARC.swift
//  yo
//
//  Created by Lukas Kollmer on 16.09.18.
//  Copyright © 2018 Lukas Kollmer. All rights reserved.
//

import Foundation


// Every object's first field (64 bit wide) stores the following data:
// - in the upper 32 bits: a pointer to a pointer to the object's metatype (32 bits are sufficient here since metatypes are stored as globals, at the beginning of the heap)
// - in the lower 32 bits: the object's


private struct ObjectMetadataAccessor {
    private enum Flags: Int, CaseIterable {
        case isDeallocating = 1
        case isMarkedForRelease
        
        var mask: Int {
            return 1 << (31 - self.rawValue)
        }
    }
    
    static let retainCountMask = Int(UInt32.max >> (Flags.allCases.count + 1))
    
    //let contents: UnsafeMutablePointer<Int>
    let address: Int
    let heap: Heap
    
    private var metadata: Int {
        get {
            return heap[address]
        }
        set {
            heap[address] = newValue
        }
    }
    
    var retainCount: Int {
        return metadata & ObjectMetadataAccessor.retainCountMask
    }
    
    var isDeallocating: Bool {
        get {
            return metadata & Flags.isDeallocating.mask != 0
        }
        set {
            guard !isDeallocating else {
                fatalError("Internal inconsistency: object at \(address.asHexString) is already deallocating")
            }
            metadata |= Flags.isDeallocating.mask
        }
    }
    
    var isMarkedForRelease: Bool {
        get {
            return metadata & Flags.isMarkedForRelease.mask != 0
        }
        
        set {
            switch newValue {
            case true:
                guard !isMarkedForRelease else {
                    fatalError("Internal inconsistency: object at \(address.asHexString) is already marked for release")
                }
                metadata |= Flags.isMarkedForRelease.mask
                
            case false:
                guard isMarkedForRelease else {
                    fatalError("Internal inconsistency: object at \(address.asHexString) is already not marked for release")
                }
                metadata &= ~Flags.isMarkedForRelease.mask
            }
        }
    }
}



enum ARC {
    static func isObject(_ address: Int, _ heap: Heap) -> Bool {
        return address != 0 && address % 16 == 0 && heap[_64: address] != 0
    }
    
    @discardableResult
    static func retain(_ address: Int, heap: Heap) -> Int {
        guard isObject(address, heap) else {
            return address
        }
        
        var metadata = ObjectMetadataAccessor(address: address, heap: heap)
        
        // TODO don't retain if the object is being deallocated? // THIS IS IMPORTANT
        
        
        if metadata.isMarkedForRelease {
            metadata.isMarkedForRelease = false
            return address
        }
        
        heap[address] += 1
        return address
    }
    
    
    @discardableResult
    static func release(_ address: Int, interpreter: BytecodeInterpreter) -> Int {
        let heap = interpreter.heap
        
        guard isObject(address, heap) else {
            return address
        }
        
        var metadata = ObjectMetadataAccessor(address: address, heap: heap)
        
        if metadata.isDeallocating {
            // the object is already in the process of being deallocated, so we'll just ignore this release call
            return address
        }
        
        if metadata.isMarkedForRelease {
            // we reach here when releasing the unused return vslue from a function call returning a complex object
            metadata.isMarkedForRelease = false
        }
        
        if metadata.retainCount == 1 {
            metadata.isDeallocating = true
        
            let typeof = interpreter.procedureEntryAddresses[reverse: SymbolMangling.mangleStaticMember(ofType: "runtime", memberName: "typeof")]!
            let type = interpreter.call(address: typeof, arguments: [address])
            let dealloc_fn_address: Int = heap[type + sizeof(.i64) + sizeof(.String)] // TODO this is tied to the structure of the `Type` struct, which is bad
            _ = interpreter.call(address: dealloc_fn_address, arguments: [address])
            
            heap.free(address: address)
        } else {
            heap[address] -= 1
        }
        
        return address
    }
}


class NativeFunctions_MemoryManagement: NativeFunctions {
    
    static func register(_ runtime: Runtime) {
        
        // MARK: Memory allocation
        
        runtime["runtime", "alloc", .int, [.int]] = { interpreter in
            let size = interpreter.stack.peek()
            return interpreter.heap.alloc(size: size)
        }
        
        runtime["runtime", "free", .void, [.int]] = { interpreter in
            let address = interpreter.stack.peek()
            interpreter.stack.heap.free(address: address)
            return 0
        }
        
        
        // MARK: Reference Counting
        
        
        runtime["runtime", "getRetainCount", .i64, [.any]] = { interpreter in
            return ObjectMetadataAccessor(address: interpreter.stack.peek(), heap: interpreter.heap).retainCount
        }
        
        runtime["runtime", "markForRelease", .i64, [.any]] = { interpreter in
            var metadata = ObjectMetadataAccessor(address: interpreter.stack.peek(), heap: interpreter.heap)
            metadata.isMarkedForRelease = true
            return 0
        }
        
        runtime["runtime", "retain", .any, [.any]] = { interpreter in
            return ARC.retain(interpreter.stack.peek(), heap: interpreter.heap)
        }
        
        runtime["runtime", "release", .any, [.any]] = { interpreter in
            return ARC.release(interpreter.stack.peek(), interpreter: interpreter)
        }
    }
}