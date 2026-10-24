//! The Chief of Staff claim this device holds
//! (docs/design/20261019-chief-of-staff.md §7.3).
//!
//! One record per device, in `durable_state_dir` beside `host.id`: a claim
//! describes the host, not one daemon process, so it outlives a restart the
//! same way the host id does.

use crate::protocol::ChiefClaim;
use anyhow::Result;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

const FILE_NAME: &str = "chief.json";

/// What a `set_chief` request leaves on the device, and whether it was refused.
///
/// The machine holding the claim, or anyone while nothing is claimed, may
/// replace or release it. Anyone else is refused unless the request says
/// `takeover` — the app's "Turn On Here Instead", for a machine that is gone
/// for good. A refusal leaves the record exactly as it was.
pub fn decide(
    current: Option<&ChiefClaim>,
    requested: Option<ChiefClaim>,
    holder: &str,
    takeover: bool,
) -> (Option<ChiefClaim>, bool) {
    let free_to_change = current.map_or(true, |claim| claim.machine == holder);
    if free_to_change || takeover {
        (requested, false)
    } else {
        (current.cloned(), true)
    }
}

pub struct ChiefRecord {
    path: Option<PathBuf>,
    claim: Mutex<Option<ChiefClaim>>,
}

impl ChiefRecord {
    /// Reads the record kept in `dir`. A missing or unreadable file is no
    /// claim: losing the record costs at most a second machine turning the
    /// Chief of Staff on, which the record discourages rather than prevents.
    pub fn open(dir: &Path) -> ChiefRecord {
        let path = dir.join(FILE_NAME);
        let claim: Option<ChiefClaim> = crate::tombstone::read_json(&path);
        ChiefRecord {
            path: Some(path),
            claim: Mutex::new(claim),
        }
    }

    /// A record with nowhere to persist, for a daemon whose state directory
    /// did not open. It still answers within this process's lifetime.
    pub fn detached() -> ChiefRecord {
        ChiefRecord {
            path: None,
            claim: Mutex::new(None),
        }
    }

    pub fn current(&self) -> Option<ChiefClaim> {
        self.claim.lock().unwrap().clone()
    }

    /// Applies a `set_chief` request, persisting the result when it changed.
    /// Returns the claim as it now stands and whether the request was refused.
    pub fn apply(
        &self,
        requested: Option<ChiefClaim>,
        holder: &str,
        takeover: bool,
    ) -> Result<(Option<ChiefClaim>, bool)> {
        let mut guard = self.claim.lock().unwrap();
        let (next, refused) = decide((*guard).as_ref(), requested, holder, takeover);
        if !refused && next != *guard {
            if let Some(path) = &self.path {
                match &next {
                    Some(claim) => crate::tombstone::write_json(path, claim)?,
                    None => match std::fs::remove_file(path) {
                        Ok(()) => {}
                        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                        Err(error) => return Err(error.into()),
                    },
                }
            }
            *guard = next.clone();
        }
        Ok((next, refused))
    }
}

#[cfg(test)]
mod tests {
    use super::{decide, ChiefRecord};
    use crate::protocol::ChiefClaim;

    fn claim(machine: &str) -> ChiefClaim {
        ChiefClaim {
            machine: machine.to_string(),
            machine_name: format!("{machine} Mac"),
            session: format!("termio://session/{machine}"),
            since_unix: 1_700_000_000,
        }
    }

    #[test]
    fn only_the_holder_changes_a_claim_unless_it_is_taken_over() {
        let mine = claim("laptop");
        let theirs = claim("mini");
        assert_eq!(
            decide(None, Some(mine.clone()), "laptop", false),
            (Some(mine.clone()), false)
        );
        assert_eq!(
            decide(Some(&mine), Some(mine.clone()), "laptop", false),
            (Some(mine.clone()), false)
        );
        assert_eq!(decide(Some(&mine), None, "laptop", false), (None, false));
        assert_eq!(
            decide(Some(&mine), Some(theirs.clone()), "mini", false),
            (Some(mine.clone()), true)
        );
        assert_eq!(
            decide(Some(&mine), None, "mini", false),
            (Some(mine.clone()), true)
        );
        assert_eq!(
            decide(Some(&mine), Some(theirs.clone()), "mini", true),
            (Some(theirs), false)
        );
        assert_eq!(decide(None, None, "mini", false), (None, false));
    }

    #[test]
    fn a_claim_survives_a_restart_and_a_release_removes_it() {
        let dir = std::env::temp_dir().join(format!("termiod-chief-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let record = ChiefRecord::open(&dir);
        assert_eq!(record.current(), None);
        let (stands, refused) = record.apply(Some(claim("laptop")), "laptop", false).unwrap();
        assert!(!refused);
        assert_eq!(stands, Some(claim("laptop")));
        drop(record);

        let reopened = ChiefRecord::open(&dir);
        assert_eq!(reopened.current(), Some(claim("laptop")));
        let (stands, refused) = reopened.apply(Some(claim("mini")), "mini", false).unwrap();
        assert!(refused);
        assert_eq!(stands, Some(claim("laptop")));
        let (stands, refused) = reopened.apply(None, "laptop", false).unwrap();
        assert!(!refused);
        assert_eq!(stands, None);
        assert!(!dir.join("chief.json").exists());

        let _ = std::fs::remove_dir_all(&dir);
    }
}
