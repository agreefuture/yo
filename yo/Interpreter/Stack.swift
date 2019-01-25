//
//  Stack.swift
//  yo
//
//  Created by Lukas Kollmer on 26.05.18.
//  Copyright © 2018 Lukas Kollmer. All rights reserved.
//

import Foundation


// A wrapper around a `Heap` that implements a stack growing from the end of the heap
class Stack: CustomStringConvertible {
    unowned let heap: Heap // TODO does unowned make sense here?
    let size: Int
    
    var stackPointer = -1
    var framePointer = -1
    
    init(heap: Heap) {
        self.heap = heap
        self.size = heap.size
    }
    
    var isEmpty: Bool {
        return stackPointer == -1
    }
    
    func actualIndex(for index: Int) -> Int {
        return heap.size - (index * 8) - 8
    }
    
    func push(_ newValue: Int) {
        stackPointer += 1
        heap[actualIndex(for: stackPointer)] = newValue
    }
    
    @discardableResult
    func pop() -> Int {
        let value: Int = heap[actualIndex(for: stackPointer)]
        heap[actualIndex(for: stackPointer)] = heap.initialValue
        stackPointer -= 1
        return value
    }
    
    func pushFrame(index: Int, value: Int) {
        heap[actualIndex(for: framePointer + index)] = value
    }
    
    func getFrameElement(atIndex index: Int) -> Int {
        return heap[actualIndex(for: framePointer + index)]
    }
    
    func peek(offset: Int = 0) -> Int {
        return heap[actualIndex(for: stackPointer + offset)]
    }
    
    
    private var elements: UnsafeBufferPointer<Int> {
        let index = actualIndex(for: stackPointer)
        return UnsafeBufferPointer<Int>(start: heap.base.advanced(by: index).assumingMemoryBound(to: Int.self), count: stackPointer)
    }
    
    
    var description: String {
        return "<Stack sp=\(stackPointer) fp=\(framePointer) elements=\(elements)>"
    }
}
