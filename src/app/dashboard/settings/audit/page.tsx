import { createClient } from "@/lib/supabase/server";
import { NoSettingsAccess } from "@/components/settings/no-settings-access";
import { AuditFilters, ENTITY_OPTIONS } from "@/components/settings/audit-filters";
import { AuditDetailButton } from "@/components/settings/audit-detail-button";
import { DataTable } from "@/components/ui/data-table";

// audit_row_change stores action as "<entity>.created|updated|deleted".
const ACTION_LABEL: Record<string, string> = {
  created: "تسجيل",
  updated: "تعديل",
  deleted: "حذف",
};

function actionLabel(action: string) {
  const suffix = action.split(".").pop() ?? action;
  return ACTION_LABEL[suffix] ?? action;
}

function entityLabel(entity: string) {
  return ENTITY_OPTIONS.find((o) => o.value === entity)?.label ?? entity;
}

type AuditRow = {
  id: string;
  created_at: string;
  user_email: string | null;
  action: string;
  entity: string;
  entity_id: string | null;
  before_data: unknown;
  after_data: unknown;
};

export default async function AuditSettingsPage(props: { searchParams: Promise<{ entity?: string }> }) {
  const searchParams = await props.searchParams;
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return null;

  const { data: membership } = await supabase
    .from("organization_users")
    .select("organization_id")
    .eq("user_id", user.id)
    .eq("status", "active")
    .order("created_at", { ascending: true })
    .limit(1)
    .maybeSingle();
  if (!membership) return null;

  const { data: canView } = await supabase.rpc("has_permission", {
    target_org: membership.organization_id,
    perm_key: "audit.view",
  });

  if (!canView) return <NoSettingsAccess message="ليس لديك صلاحية الاطلاع على سجل العمليات." />;

  const entity = searchParams.entity ?? "";
  let query = supabase
    .from("audit_logs")
    .select("id, created_at, user_email, action, entity, entity_id, before_data, after_data")
    .order("created_at", { ascending: false })
    .limit(200);
  if (entity) query = query.eq("entity", entity);

  const { data: rows } = await query;

  return (
    <div>
      <div className="mb-5 flex items-center justify-between gap-4">
        <p className="text-xs leading-6 text-charcoal/45">
          كل عملية تسجيل، تعديل، أو حذف على البيانات المالية والحساسة تُسجَّل هنا تلقائيًا ولا يمكن تعديلها أو حذفها. آخر 200 عملية.
        </p>
        <AuditFilters entity={entity} />
      </div>

      <DataTable<AuditRow>
        rows={(rows as AuditRow[]) ?? []}
        getRowKey={(r) => r.id}
        emptyLabel="لا توجد عمليات مسجّلة بعد"
        columns={[
          {
            header: "الوقت",
            render: (r) => (
              <span dir="ltr" className="text-xs text-charcoal/60">
                {new Date(r.created_at).toLocaleString("ar-EG")}
              </span>
            ),
          },
          { header: "المستخدم", render: (r) => r.user_email ?? "النظام" },
          { header: "الإجراء", render: (r) => actionLabel(r.action) },
          { header: "النوع", render: (r) => entityLabel(r.entity) },
          { header: "التفاصيل", render: (r) => <AuditDetailButton before={r.before_data} after={r.after_data} /> },
        ]}
      />
    </div>
  );
}
