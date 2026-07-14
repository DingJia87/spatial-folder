import fs from "node:fs/promises";
import { Presentation, PresentationFile, SpreadsheetFile, Workbook } from "@oai/artifact-tool";

const output = new URL("../Sources/SpatialFolder/Resources/", import.meta.url);
await fs.mkdir(output, { recursive: true });

const workbook = Workbook.create();
workbook.worksheets.add("Sheet1");
const spreadsheet = await SpreadsheetFile.exportXlsx(workbook);
await spreadsheet.save(new URL("BlankWorkbook.xlsx", output).pathname);

const presentation = Presentation.create({ slideSize: { width: 1280, height: 720 } });
presentation.slides.add();
const deck = await PresentationFile.exportPptx(presentation);
await deck.save(new URL("BlankPresentation.pptx", output).pathname);
