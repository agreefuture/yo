//
//  NativeFunction.swift
//  yo
//
//  Created by Lukas Kollmer on 25.05.18.
//  Copyright © 2018 Lukas Kollmer. All rights reserved.
//

import Foundation


extension Runtime {
    
    private static var _address = -1000
    private static var addr: Int {
        _address += 1
        return _address
    }
    
    private static func ns(_ ns: String, _ name: String) -> String {
        return SymbolMangling.mangleStaticMember(ofType: ns, memberName: name)
    }
    
    typealias NativeFunctionImp = (StackView) -> Int
    typealias NativeFunction = (name: String, argc: Int, address: Int, imp: NativeFunctionImp)
    
    static let builtins: [NativeFunction] = [
        (ns("runtime", "alloc"),            1, addr, alloc  ),
        (ns("runtime", "retain"),           1, addr, retain ),
        (ns("runtime", "_release"),          1, addr, runtime__release),
        (ns("runtime", "free"),             1, addr, runtime_free),
        (ns("runtime", "_getRetainCount"),  1, addr, getRetainCount),
        (ns("runtime", "dealloc"),          1, addr, { _ in 0 }),   // implemented manually in -[BytecodeInterpreter run]
        (ns("io", "print"),                 1, addr, io_printf),    // TODO make this variardic?
        (ns("io", "printi"),                1, addr, io_printi),
    ]
    
    
    static func getNativeFunction(withAddress address: Int) -> NativeFunction {
        if let builtin = builtins.first(where: { $0.address == address }) {
            return builtin
        }
        fatalError("no native func at address \(address)")
    }
    
    
    static func builtin(withName name: String) -> NativeFunction? {
        return builtins.first { $0.name == name }
    }
    
    
    // MARK: Native functions
    
    private static func alloc(_ stack: StackView) -> Int {
        let size = stack.peek()
        let address = stack.heap.alloc(size: size)
        //stack.heap.retain(address: address)
        return address
    }
    
    
    // MARK: Reference Counting
    
    private static func getRetainCount(_ stack: StackView) -> Int {
        return stack.heap.retainCount(ofAddress: stack.peek())
    }
    
    private static func retain(_ stack: StackView) -> Int {
        stack.heap.retain(address: stack.peek())
        return 0
    }
    
    private static func runtime__release(_ stack: StackView) -> Int {
        stack.heap.release(address: stack.peek())
        return 0
    }
    
    private static func runtime_free(_ stack: StackView) -> Int {
        stack.heap.free(address: stack.peek())
        return 0;
    }
    
    
    // MARK: io
    
    // print a string
    private static func io_printf(_ stack: StackView) -> Int {
        let address = stack.heap[stack.peek() + 1]
        let size = stack.heap[address]
        
        let start = address + 1
        let end = start + size
        
        let characters: [Character] = stack.heap[start..<end]
            .compactMap(UnicodeScalar.init)
            .map(Character.init)
        
        print(String(characters))
        return 0
    }
    
    // print an integer
    private static func io_printi(_ stack: StackView) -> Int {
        print(stack.peek())
        return 0;
    }
}
