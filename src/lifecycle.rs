//! Final-state lifecycle planner. Physical maintenance operations are intentionally absent.

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ActivationState {
    pub active: bool,
    /// The latest generation, including a generation that has since ended.
    pub generation: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EventKind {
    Activate,
    Deactivate,
    Noop,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Transition {
    pub event: EventKind,
    pub generation: u64,
    pub next: ActivationState,
}

/// Plans exactly one semantic outcome from the durable state and final membership.
pub fn plan(previous: ActivationState, present: bool) -> Transition {
    match (previous.active, present) {
        (false, true) => {
            let generation = previous
                .generation
                .checked_add(1)
                .expect("activation generation overflow");
            Transition {
                event: EventKind::Activate,
                generation,
                next: ActivationState {
                    active: true,
                    generation,
                },
            }
        }
        (true, false) => Transition {
            event: EventKind::Deactivate,
            generation: previous.generation,
            next: ActivationState {
                active: false,
                ..previous
            },
        },
        _ => Transition {
            event: EventKind::Noop,
            generation: previous.generation,
            next: previous,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generation_advances_only_on_reactivation() {
        let first = plan(ActivationState::default(), true);
        assert_eq!(first.event, EventKind::Activate);
        assert_eq!(first.generation, 1);
        assert_eq!(plan(first.next, true).event, EventKind::Noop);
        let closed = plan(first.next, false);
        assert_eq!(closed.event, EventKind::Deactivate);
        assert_eq!(closed.generation, 1);
        let second = plan(closed.next, true);
        assert_eq!((second.event, second.generation), (EventKind::Activate, 2));
    }
}
