//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2018 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation

/// Abstraction layer so we can store a heterogeneous collection of tasks in an
/// array.
private protocol AnyTask: Sendable {
  func waitForCompletion() async
}

extension Task: AnyTask {
  func waitForCompletion() async {
    _ = try? await value
  }
}

extension NSLock {
  /// NOTE: Keep in sync with SwiftPM's 'Sources/Basics/NSLock+Extensions.swift'
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}

/// A type that is able to track dependencies between tasks.
public protocol DependencyTracker {
  /// Whether the task described by `self` needs to finish executing before
  /// `other` can start executing.
  func isDependency(of other: Self) -> Bool
}

/// A dependency tracker where each task depends on every other, i.e. a serial
/// queue.
public struct Serial: DependencyTracker {
  public func isDependency(of other: Serial) -> Bool {
    return true
  }
}

/// A queue that allows the execution of asyncronous blocks of code.
public final class AsyncQueue<TaskMetadata: DependencyTracker> {
  private struct PendingTask {
    /// The task that is pending.
    let task: any AnyTask

    let metadata: TaskMetadata

    /// A unique value used to identify the task. This allows tasks to get
    /// removed from `pendingTasks` again after they finished executing.
    let id: UUID
  }

  ///  Lock guarding `pendingTasks`.
  private let pendingTasksLock = NSLock()

  /// Pending tasks that have not finished execution yet.
  private var pendingTasks = [PendingTask]()

  public init() {
    self.pendingTasksLock.name = "AsyncQueue"
  }

  /// Schedule a new closure to be executed on the queue.
  ///
  /// If this is a serial queue, all previously added tasks are guaranteed to
  /// finished executing before this closure gets executed.
  ///
  /// If this is a barrier, all previously scheduled tasks are guaranteed to
  /// finish execution before the barrier is executed and all tasks that are
  /// added later will wait until the barrier finishes execution.
  @discardableResult
  public func async<Success: Sendable>(
    priority: TaskPriority? = nil,
    metadata: TaskMetadata,
    @_inheritActorContext operation: @escaping @Sendable () async -> Success
  ) -> Task<Success, Never> {
    let throwingTask = asyncThrowing(priority: priority, metadata: metadata, operation: operation)
    return Task {
      do {
        return try await throwingTask.value
      } catch {
        // We know this can never happen because `operation` does not throw.
        preconditionFailure("Executing a task threw an error even though the operation did not throw")
      }
    }
  }

  /// Same as ``AsyncQueue/async(priority:barrier:operation:)`` but allows the
  /// operation to throw.
  ///
  /// - Important: The caller is responsible for handling any errors thrown from
  ///   the operation by awaiting the result of the returned task.
  public func asyncThrowing<Success: Sendable>(
    priority: TaskPriority? = nil,
    metadata: TaskMetadata,
    @_inheritActorContext operation: @escaping @Sendable () async throws -> Success
  ) -> Task<Success, any Error> {
    let id = UUID()

    return pendingTasksLock.withLock {
      // Build the list of tasks that need to finishe exeuction before this one
      // can be executed
      let dependencies: [PendingTask] = pendingTasks.filter { $0.metadata.isDependency(of: metadata) }

      // Schedule the task.
      let task = Task {
        // IMPORTANT: The only throwing call in here must be the call to
        // operation. Otherwise the assumption that the task will never throw
        // if `operation` does not throw, which we are making in `async` does
        // not hold anymore.
        for dependency in dependencies {
          await dependency.task.waitForCompletion()
        }

        let result = try await operation()

        pendingTasksLock.withLock {
          pendingTasks.removeAll(where: { $0.id == id })
        }

        return result
      }

      pendingTasks.append(PendingTask(task: task, metadata: metadata, id: id))

      return task
    }
  }
}

/// Convenience overloads for serial queues.
extension AsyncQueue where TaskMetadata == Serial {
  /// Same as ``async(priority:operation:)`` but specialized for serial queues 
  /// that don't specify any metadata.
  @discardableResult
  public func async<Success: Sendable>(
    priority: TaskPriority? = nil,
    @_inheritActorContext operation: @escaping @Sendable () async -> Success
  ) -> Task<Success, Never> {
    return self.async(priority: priority, metadata: Serial(), operation: operation)
  }

  /// Same as ``asyncThrowing(priority:metadata:operation:)`` but specialized 
  /// for serial queues that don't specify any metadata.
  public func asyncThrowing<Success: Sendable>(
    priority: TaskPriority? = nil,
    @_inheritActorContext operation: @escaping @Sendable () async throws -> Success
  ) -> Task<Success, any Error> {
    return self.asyncThrowing(priority: priority, metadata: Serial(), operation: operation)
  }
}
