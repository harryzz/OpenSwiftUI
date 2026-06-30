//
//  DragGesture.swift
//  OpenSwiftUICore
//
//  Status: WIP (wandr) — minimal faithful DragGesture built on EventListener<SpatialEvent>
//  + the DistanceGesture-style minimum-distance gate. Models SwiftUI's DragGesture API
//  (Value.translation / location / startLocation / time). Velocity/prediction are not yet
//  estimated (reported as zero / no projection). Mirrors DistanceGesture.swift structure.

public import Foundation

// MARK: - DragGesture

/// A dragging motion that invokes an action as the drag-event sequence changes.
///
/// To recognize a drag gesture on a view, create and configure the gesture, then
/// add it with the ``View/gesture(_:including:)`` modifier:
///
///     DragGesture()
///         .onChanged { value in offset = value.translation }
///         .onEnded { _ in offset = .zero }
public struct DragGesture: Gesture {

    /// The attributes of a drag gesture.
    public struct Value: Equatable, @unchecked Sendable {
        /// The time associated with the current drag event.
        public var time: Date

        /// The location of the current drag event.
        public var location: CGPoint

        /// The location of the first drag event (where the drag began).
        public var startLocation: CGPoint

        /// The current drag velocity, in points per second.
        /// (wandr: not yet estimated — reported as zero.)
        public var velocity: CGSize

        /// The total translation from the start of the drag to the current event.
        public var translation: CGSize {
            CGSize(width: location.x - startLocation.x, height: location.y - startLocation.y)
        }

        /// A prediction of where the drag would end, based on velocity.
        /// (wandr: no velocity estimate yet → the current location.)
        public var predictedEndLocation: CGPoint { location }

        /// A prediction of the drag translation at the predicted end location.
        public var predictedEndTranslation: CGSize { translation }
    }

    /// Per-sequence state: the start location and the largest distance reached so far
    /// (used to satisfy `minimumDistance` before the drag becomes active).
    package struct StateType: GestureStateProtocol {
        var startLocation: CGPoint?
        var maxDistance: CGFloat

        package init() {
            startLocation = nil
            maxDistance = .zero
        }

        /// Records `location` against the sequence start, updates `maxDistance`, and returns
        /// the (sticky) start location.
        mutating func update(to location: CGPoint) -> CGPoint {
            if let startLocation {
                maxDistance = max(maxDistance, distance(startLocation, location))
                return startLocation
            } else {
                startLocation = location
                return location
            }
        }
    }

    /// The minimum dragging distance before the gesture succeeds.
    public var minimumDistance: CGFloat

    /// The coordinate space in which to receive location values.
    public var coordinateSpace: CoordinateSpace

    /// Creates a dragging gesture.
    /// - Parameters:
    ///   - minimumDistance: The minimum drag distance before the gesture becomes active.
    ///   - coordinateSpace: The coordinate space of the drag location values.
    public init(minimumDistance: CGFloat = 10, coordinateSpace: CoordinateSpace = .local) {
        self.minimumDistance = minimumDistance
        self.coordinateSpace = coordinateSpace
    }

    public var body: some Gesture<DragGesture.Value> {
        let minimumDistance = minimumDistance
        return StateType.gesture(content: EventListener<SpatialEvent>()) { state, phase in
            func makeValue(_ event: SpatialEvent, _ start: CGPoint) -> DragGesture.Value {
                DragGesture.Value(
                    time: Date(timeIntervalSinceReferenceDate: event.timestamp.seconds),
                    location: event.location,
                    startLocation: start,
                    velocity: .zero
                )
            }
            switch phase {
            case let .possible(event):
                guard let event else { return .possible(nil) }
                let start = state.update(to: event.location)
                return .possible(makeValue(event, start))
            case let .active(event):
                let start = state.update(to: event.location)
                guard state.maxDistance >= minimumDistance else {
                    return .possible(makeValue(event, start))
                }
                return .active(makeValue(event, start))
            case let .ended(event):
                let start = state.update(to: event.location)
                guard state.maxDistance >= minimumDistance else {
                    return .failed
                }
                return .ended(makeValue(event, start))
            case .failed:
                return .failed
            }
        }
    }
}
