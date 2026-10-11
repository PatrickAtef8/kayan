"use client";

import { useEffect, useRef, useState } from "react";
import { Paperclip, Upload, Trash2, FileText } from "lucide-react";
import { createClient } from "@/lib/supabase/client";

type Attachment = { id: string; storage_path: string; file_name: string; file_size: number | null; created_at: string };

const MAX_FILE_SIZE = 10 * 1024 * 1024; // 10MB — receipts/scans, not media libraries

function formatSize(bytes: number | null) {
  if (!bytes) return "";
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} كيلوبايت`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} ميجابايت`;
}

export function AttachmentsPanel({
  organizationId,
  entityType,
  entityId,
}: {
  organizationId: string;
  entityType: "expense" | "sales_invoice" | "purchase_invoice" | "customer" | "supplier";
  entityId: string;
}) {
  const supabase = createClient();
  const fileInputRef = useRef<HTMLInputElement>(null);
  const [attachments, setAttachments] = useState<Attachment[]>([]);
  const [loading, setLoading] = useState(true);
  const [uploading, setUploading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  function queryAttachments() {
    return supabase
      .from("attachments")
      .select("id, storage_path, file_name, file_size, created_at")
      .eq("entity_type", entityType)
      .eq("entity_id", entityId)
      .order("created_at", { ascending: false });
  }

  async function refresh() {
    setLoading(true);
    const { data } = await queryAttachments();
    setAttachments(data ?? []);
    setLoading(false);
  }

  // A different record starts a new load: raise the flag while rendering, not inside the effect.
  const recordKey = `${entityType}:${entityId}`;
  const [prevRecordKey, setPrevRecordKey] = useState(recordKey);
  if (recordKey !== prevRecordKey) {
    setPrevRecordKey(recordKey);
    setLoading(true);
  }

  useEffect(() => {
    queryAttachments().then(({ data }) => {
      setAttachments(data ?? []);
      setLoading(false);
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [entityType, entityId]);

  async function handleUpload(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    if (!file) return;
    e.target.value = "";

    if (file.size > MAX_FILE_SIZE) {
      setError("حجم الملف أكبر من 10 ميجابايت");
      return;
    }
    setError(null);
    setUploading(true);

    const safeName = file.name.replace(/[^\w.\-\u0600-\u06FF ]/g, "_");
    const path = `${organizationId}/${entityType}/${entityId}/${Date.now()}_${safeName}`;

    const { error: uploadError } = await supabase.storage.from("attachments").upload(path, file);
    if (uploadError) {
      setError(uploadError.message);
      setUploading(false);
      return;
    }

    const { error: insertError } = await supabase.from("attachments").insert({
      organization_id: organizationId,
      entity_type: entityType,
      entity_id: entityId,
      storage_path: path,
      file_name: file.name,
      file_size: file.size,
      content_type: file.type || null,
    });
    if (insertError) {
      setError(insertError.message);
      await supabase.storage.from("attachments").remove([path]);
      setUploading(false);
      return;
    }

    setUploading(false);
    refresh();
  }

  async function handleOpen(attachment: Attachment) {
    const { data, error: signError } = await supabase.storage.from("attachments").createSignedUrl(attachment.storage_path, 60);
    if (signError || !data) {
      setError("تعذّر فتح الملف");
      return;
    }
    window.open(data.signedUrl, "_blank", "noopener,noreferrer");
  }

  async function handleDelete(attachment: Attachment) {
    const { error: deleteError } = await supabase.from("attachments").delete().eq("id", attachment.id);
    if (deleteError) {
      setError(deleteError.message);
      return;
    }
    await supabase.storage.from("attachments").remove([attachment.storage_path]);
    refresh();
  }

  return (
    <div>
      <div className="mb-2 flex items-center justify-between">
        <p className="flex items-center gap-1.5 text-xs font-medium text-charcoal/50">
          <Paperclip size={13} strokeWidth={1.8} />
          المرفقات
        </p>
        <button
          type="button"
          disabled={uploading}
          onClick={() => fileInputRef.current?.click()}
          className="flex items-center gap-1 text-xs font-medium text-sage hover:underline disabled:opacity-50"
        >
          <Upload size={12} strokeWidth={2} />
          {uploading ? "جارٍ الرفع..." : "إرفاق ملف"}
        </button>
        <input ref={fileInputRef} type="file" className="hidden" onChange={handleUpload} />
      </div>

      {error && <p className="mb-2 text-xs text-rose">{error}</p>}

      {loading ? (
        <p className="text-xs text-charcoal/35">جارٍ التحميل...</p>
      ) : attachments.length === 0 ? (
        <p className="text-xs text-charcoal/35">لا توجد مرفقات</p>
      ) : (
        <div className="space-y-1.5">
          {attachments.map((a) => (
            <div key={a.id} className="flex items-center justify-between rounded-lg border border-borderSoft px-3 py-2">
              <button type="button" onClick={() => handleOpen(a)} className="flex min-w-0 items-center gap-2 text-right hover:text-sage">
                <FileText size={14} strokeWidth={1.8} className="shrink-0 text-charcoal/35" />
                <span className="truncate text-xs text-charcoal">{a.file_name}</span>
                <span className="shrink-0 text-[0.6875rem] text-charcoal/35" dir="ltr">
                  {formatSize(a.file_size)}
                </span>
              </button>
              <button type="button" onClick={() => handleDelete(a)} className="shrink-0 rounded p-1 text-charcoal/30 hover:text-rose">
                <Trash2 size={13} strokeWidth={1.8} />
              </button>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
