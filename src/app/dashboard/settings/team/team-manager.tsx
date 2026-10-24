"use client";

import { useRouter } from "next/navigation";
import { AddMemberForm } from "./add-member-form";
import { TeamList } from "./team-list";

type Member = { user_id: string; email: string; role_id: string; role_key: string; role_name: string; status: string; is_self: boolean; display_name: string | null };
type RoleOption = { id: string; name: string };

export function TeamManager({ members, roles, linkedUserIds, freeReps }: { members: Member[]; roles: RoleOption[]; linkedUserIds: string[]; freeReps: { id: string; name: string }[] }) {
  const router = useRouter();
  return (
    <div>
      <AddMemberForm roles={roles} onAdded={() => router.refresh()} />
      <TeamList members={members} roles={roles} linkedUserIds={linkedUserIds} freeReps={freeReps} />
    </div>
  );
}
