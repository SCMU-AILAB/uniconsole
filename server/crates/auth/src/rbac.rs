//! 权限矩阵，来自 Roles.dc.html：
//!
//! | 权限                 | 管理员 | 管理者 | 使用者 | 观察者 |
//! |----------------------|--------|--------|--------|--------|
//! | 查看设备状态         | ●      | ●      | ◐      | ◐      |
//! | 查看视频与传感器     | ●      | ●      | ◐      | ◐      |
//! | 申请 / 持有控制权    | ●      | ◐      | ◐      | —      |
//! | 发起多机联调         | ●      | ◐      | —      | —      |
//! | 编辑地图、任务与围栏 | ●      | ◐      | —      | —      |
//! | 固件升级与远程终端   | ●      | ◐      | —      | —      |
//! | 分配使用者           | ●      | ◐      | —      | —      |
//! | 管理成员与角色       | ●      | —      | —      | —      |
//! | 急停（任何人）       | ●      | ●      | ●      | ●      |
//!
//! ● = 全部设备；◐ = 仅自己管理或被授权的设备（Scoped）。

use uniconsole_domain::Role;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Perm {
    ViewDevice,
    ViewSensors,
    HoldLease,
    FleetSession,
    EditMaps,
    Maintenance,
    AssignUsers,
    ManageMembers,
    Estop,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Access {
    None,
    Scoped,
    All,
}

pub fn access(role: Role, perm: Perm) -> Access {
    use Access::*;
    use Perm::*;
    match (perm, role) {
        (_, Role::Admin) => All,
        (Estop, _) => All,
        (ViewDevice | ViewSensors, Role::Owner) => All,
        (ViewDevice | ViewSensors, Role::User | Role::Viewer) => Scoped,
        (HoldLease, Role::Owner | Role::User) => Scoped,
        (FleetSession | EditMaps | Maintenance | AssignUsers, Role::Owner) => Scoped,
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matrix() {
        assert_eq!(access(Role::Viewer, Perm::Estop), Access::All);
        assert_eq!(access(Role::Viewer, Perm::HoldLease), Access::None);
        assert_eq!(access(Role::User, Perm::HoldLease), Access::Scoped);
        assert_eq!(access(Role::Owner, Perm::ManageMembers), Access::None);
        assert_eq!(access(Role::Owner, Perm::ViewDevice), Access::All);
        assert_eq!(access(Role::Admin, Perm::ManageMembers), Access::All);
    }
}
