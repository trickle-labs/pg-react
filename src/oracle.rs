//! Small deterministic reference model used to check planner histories.

use std::collections::{BTreeMap, BTreeSet};

use crate::lifecycle::{ActivationState, Transition, plan};

#[derive(Debug, Default)]
pub struct ReferenceOracle {
    states: BTreeMap<i64, ActivationState>,
}

impl ReferenceOracle {
    /// Applies a whole final match set, coalescing any physical history into one transition per key.
    pub fn apply_final_matches<I>(&mut self, matches: I) -> Vec<(i64, Transition)>
    where
        I: IntoIterator<Item = i64>,
    {
        let matches: BTreeSet<_> = matches.into_iter().collect();
        let keys: BTreeSet<_> = self
            .states
            .keys()
            .copied()
            .chain(matches.iter().copied())
            .collect();
        keys.into_iter()
            .map(|key| {
                let transition = plan(
                    *self.states.get(&key).unwrap_or(&ActivationState::default()),
                    matches.contains(&key),
                );
                self.states.insert(key, transition.next);
                (key, transition)
            })
            .collect()
    }

    pub fn active_keys(&self) -> BTreeSet<i64> {
        self.states
            .iter()
            .filter_map(|(&key, state)| state.active.then_some(key))
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lifecycle::EventKind;

    #[test]
    fn final_set_coalesces_delete_insert_into_noop() {
        let mut oracle = ReferenceOracle::default();
        oracle.apply_final_matches([7]);
        let transitions = oracle.apply_final_matches([7]);
        assert_eq!(
            transitions,
            vec![(
                7,
                Transition {
                    event: EventKind::Noop,
                    generation: 1,
                    next: ActivationState {
                        active: true,
                        generation: 1
                    }
                }
            )]
        );
    }

    #[test]
    fn same_seed_replays_the_same_history_and_outcome() {
        #[allow(clippy::type_complexity)]
        fn replay(
            mut seed: u64,
        ) -> (
            Vec<(i64, bool)>,
            Vec<Vec<(i64, Transition)>>,
            BTreeMap<i64, ActivationState>,
        ) {
            let mut history = Vec::new();
            let mut transitions = Vec::new();
            let mut oracle = ReferenceOracle::default();
            let mut expected = BTreeSet::new();
            for _ in 0..1_000 {
                seed = seed.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1);
                let key = ((seed >> 32) % 16) as i64;
                let present = seed & 1 == 0;
                history.push((key, present));
                if present {
                    expected.insert(key);
                } else {
                    expected.remove(&key);
                }
                transitions.push(oracle.apply_final_matches(expected.iter().copied()));
                assert_eq!(oracle.active_keys(), expected);
            }
            (history, transitions, oracle.states)
        }

        let first = replay(0x5eed);
        let second = replay(0x5eed);
        assert_eq!(first, second);
    }

    #[test]
    fn long_physical_histories_preserve_final_membership() {
        let mut seed = 0x5eed_u64;
        let mut oracle = ReferenceOracle::default();
        let mut expected = BTreeSet::new();

        for _ in 0..1_000 {
            seed = seed.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1);
            let key = ((seed >> 32) % 16) as i64;
            match seed % 6 {
                0 => {
                    expected.insert(key);
                } // insert
                1 => {} // update: membership is unchanged in M1
                2 => {
                    expected.remove(&key);
                } // delete
                3 => {
                    expected.remove(&key);
                    expected.insert(key);
                } // delete+insert
                4 | 5 => {} // rebuild and STATE_ONLY reconciliation read final membership
                _ => unreachable!(),
            }
            oracle.apply_final_matches(expected.iter().copied());
            assert_eq!(oracle.active_keys(), expected);
        }
    }
}
