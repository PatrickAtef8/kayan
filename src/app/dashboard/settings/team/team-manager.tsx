"use client";

import { useRouter } from "next/navigation";
import { AddMemberForm } from "./add-member-form";
import { TeamList } from "./team-list";
import { RoleManager, type CustomRole } from "./role-manager";
import type { PermissionOption } from "./role-editor-modal";

type Member = { user_id: string; email: string; role_id: string; role_key: string; role_name: string; status: string; is_self: boolean };
type RoleOption = { id: string; name: string };

export function TeamManager({
  members,
  roles,
  customRoles,
  permissions,
}: {
  members: Member[];
  roles: RoleOption[];
  customRoles: CustomRole[];
  permissions: PermissionOption[];
}) {
  const router = useRouter();

  return (
    <div>
      <AddMemberForm roles={roles} onAdded={() => router.refresh()} />
      <TeamList members={members} roles={roles} />
      <RoleManager customRoles={customRoles} permissions={permissions} />
    </div>
  );
}
