import type { Feature } from "write-excel-file/universal";

// write-excel-file covers cells, styles, merges, frozen rows and RTL, but not what makes a sheet pleasant to USE and
// PRINT: a filter on the header row, a header row repeated on every printed page, "fit to one page wide", page
// numbers. This small "feature" (the library's own extension point) adds them by editing the generated XML.
//
// Element order inside <worksheet> is fixed by the OOXML schema and Excel refuses files that break it, so every
// insertion below goes at a place that keeps that order:
//   sheetPr, sheetViews, cols, sheetData, autoFilter, mergeCells, printOptions, pageMargins, pageSetup, headerFooter

export type SheetExtras = {
  /** Header row of the table, 1-based, and the columns it spans (1-based, inclusive). */
  table?: { headerRow: number; lastRow: number; firstCol: number; lastCol: number };
  landscape?: boolean;
  /** Tab colour, "RRGGBB". */
  tabColor?: string;
  /** Repeat this row at the top of every printed page, 1-based. */
  printTitleRow?: number;
  /** Text for the printed footer (centre shows "page x of y"). */
  footerLeft?: string;
};

function colLetters(n: number): string {
  let s = "";
  while (n > 0) {
    const m = (n - 1) % 26;
    s = String.fromCharCode(65 + m) + s;
    n = Math.floor((n - 1) / 26);
  }
  return s;
}

const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
// In a header/footer string "&" starts a code, so a literal one is written "&&".
const hf = (s: string) => esc(s.replace(/&/g, "&&"));
const quoteSheet = (name: string) => `'${name.replace(/'/g, "''")}'`;

export function excelExtras(extras: SheetExtras[], sheetNames: string[]): Feature<Blob> {
  return {
    files: {
      transform: {
        "xl/worksheets/sheet{id}.xml": {
          transform(xml, _options, props) {
            const x = extras[props.sheetIndex];
            if (!x) return xml;
            let out = xml;

            // 1. <sheetPr> must be the first child of <worksheet>.
            const sheetPr =
              `<sheetPr>${x.tabColor ? `<tabColor rgb="FF${x.tabColor}"/>` : ""}<pageSetUpPr fitToPage="1"/></sheetPr>`;
            if (!/<sheetPr[\s>/]/.test(out)) out = out.replace(/(<worksheet\b[^>]*>)/, `$1${sheetPr}`);

            // 2. Frozen rows only: the library marks the pane "bottomRight" even without frozen columns, which makes
            //    the selection live in a pane that does not exist. Excel itself writes bottomLeft for rows-only.
            out = out.replace(/<pane ySplit="(\d+)" xSplit="0" topLeftCell="([A-Z]+\d+)" activePane="bottomRight" state="frozen"\/>/, (_m, y, cell) => {
              return `<pane ySplit="${y}" topLeftCell="${cell}" activePane="bottomLeft" state="frozen"/><selection pane="bottomLeft" activeCell="${cell}" sqref="${cell}"/>`;
            });

            // 3. Filter buttons on the header row — right after </sheetData> (before <mergeCells>).
            if (x.table && x.table.lastRow > x.table.headerRow) {
              const ref = `${colLetters(x.table.firstCol)}${x.table.headerRow}:${colLetters(x.table.lastCol)}${x.table.lastRow}`;
              out = out.replace("</sheetData>", `</sheetData><autoFilter ref="${ref}"/>`);
            }

            // 4. Print setup: A4, one page wide (any number of pages tall), centred, narrow margins, page numbers.
            const orientation = x.landscape ? ` orientation="landscape"` : ` orientation="portrait"`;
            const footer =
              `<headerFooter><oddFooter>${x.footerLeft ? `&amp;L&amp;9${hf(x.footerLeft)}` : ""}&amp;C&amp;9&amp;P / &amp;N&amp;R&amp;9&amp;D</oddFooter></headerFooter>`;
            const printBlock =
              `<printOptions horizontalCentered="1"/>` +
              `<pageMargins left="0.4" right="0.4" top="0.6" bottom="0.7" header="0.3" footer="0.3"/>` +
              `<pageSetup paperSize="9"${orientation} fitToWidth="1" fitToHeight="0"/>` +
              footer;
            out = out.replace(/<pageMargins\b[^>]*\/>/, "").replace(/<pageSetup\b[^>]*\/>/, "");
            out = out.replace("</worksheet>", `${printBlock}</worksheet>`);
            return out;
          },
        },
        "xl/workbook.xml": {
          transform(xml) {
            const names: string[] = [];
            extras.forEach((x, i) => {
              const sheet = quoteSheet(sheetNames[i] ?? `Sheet${i + 1}`);
              if (x.table && x.table.lastRow > x.table.headerRow) {
                const ref = `${sheet}!$${colLetters(x.table.firstCol)}$${x.table.headerRow}:$${colLetters(x.table.lastCol)}$${x.table.lastRow}`;
                names.push(`<definedName name="_xlnm._FilterDatabase" localSheetId="${i}" hidden="1">${esc(ref)}</definedName>`);
              }
              if (x.printTitleRow) names.push(`<definedName name="_xlnm.Print_Titles" localSheetId="${i}">${esc(`${sheet}!$${x.printTitleRow}:$${x.printTitleRow}`)}</definedName>`);
            });
            if (names.length === 0) return xml.replace("<definedNames/>", "");
            return xml.replace("<definedNames/>", `<definedNames>${names.join("")}</definedNames>`);
          },
        },
      },
    },
  };
}
