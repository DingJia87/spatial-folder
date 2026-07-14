from pathlib import Path
from docx import Document

output = Path(__file__).parent.parent / "Sources" / "SpatialFolder" / "Resources"
output.mkdir(parents=True, exist_ok=True)
document = Document()
document.save(output / "BlankDocument.docx")
