#!/bin/bash

echo "=== Excel Export Test ==="
echo ""

# Test 1: Create a simple test template
echo "Test 1: Creating test template..."
TEMPLATE_PATH="/tmp/test_template.xlsx"

# Create a minimal xlsx template using Python or manual XML
python3 -c "
import subprocess
import tempfile
import os

# Create temp directory
temp_dir = tempfile.mkdtemp()
xl_dir = os.path.join(temp_dir, 'xl')
worksheets_dir = os.path.join(xl_dir, 'worksheets')
rels_dir = os.path.join(temp_dir, '_rels')
xl_rels_dir = os.path.join(xl_dir, '_rels')

os.makedirs(worksheets_dir)
os.makedirs(rels_dir)
os.makedirs(xl_rels_dir)

# Create minimal files
content_types = '''<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>
<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">
    <Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>
    <Default Extension=\"xml\" ContentType=\"application/xml\"/>
    <Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>
    <Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>
    <Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>
</Types>'''

with open(os.path.join(temp_dir, '[Content_Types].xml'), 'w') as f:
    f.write(content_types)

# Create root rels
root_rels = '''<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>
<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">
    <Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/>
</Relationships>'''

with open(os.path.join(rels_dir, '.rels'), 'w') as f:
    f.write(root_rels)

# Create workbook
workbook = '''<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>
<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">
    <sheets>
        <sheet name=\"Sheet1\" sheetId=\"1\" r:id=\"rId1\"/>
    </sheets>
</workbook>'''

with open(os.path.join(xl_dir, 'workbook.xml'), 'w') as f:
    f.write(workbook)

# Create workbook rels
workbook_rels = '''<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>
<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">
    <Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/>
    <Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>
</Relationships>'''

with open(os.path.join(xl_rels_dir, 'workbook.xml.rels'), 'w') as f:
    f.write(workbook_rels)

# Create worksheet with headers
worksheet = '''<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>
<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">
    <sheetData>
        <row r=\"1\">
            <c r=\"A1\" t=\"inlineStr\"><is><t>需求类型</t></is></c>
            <c r=\"B1\" t=\"inlineStr\"><is><t>需求号</t></is></c>
            <c r=\"C1\" t=\"inlineStr\"><is><t>需求名称</t></is></c>
        </row>
    </sheetData>
</worksheet>'''

with open(os.path.join(worksheets_dir, 'sheet1.xml'), 'w') as f:
    f.write(worksheet)

# Create styles
styles = '''<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>
<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">
    <fonts count=\"2\">
        <font><sz val=\"11\"/><name val=\"Arial\"/></font>
        <font><b/><sz val=\"11\"/><name val=\"Arial\"/></font>
    </fonts>
    <fills count=\"2\">
        <fill><patternFill patternType=\"none\"/></fill>
        <fill><patternFill patternType=\"solid\"><fgColor rgb=\"FF4472C4\"/></patternFill></fill>
    </fills>
    <borders count=\"1\">
        <border><left/><right/><top/><bottom/><diagonal/></border>
    </borders>
    <cellXfs count=\"2\">
        <xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/>
        <xf numFmtId=\"0\" fontId=\"1\" fillId=\"1\" borderId=\"0\" applyFont=\"1\" applyFill=\"1\"/>
    </cellXfs>
</styleSheet>'''

with open(os.path.join(xl_dir, 'styles.xml'), 'w') as f:
    f.write(styles)

# Zip to create xlsx
subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', temp_dir, '$TEMPLATE_PATH'], check=True)

# Cleanup
import shutil
shutil.rmtree(temp_dir)

print('Template created successfully')
" 2>&1

if [ $? -eq 0 ]; then
    echo "✅ Template created: $TEMPLATE_PATH"
else
    echo "❌ Failed to create template"
fi

echo ""
echo "Test 2: Testing export without template..."
echo "Output: /tmp/test_no_template.xlsx"
echo "You can test this in the app by:"
echo "  1. Leave '模板路径' empty"
echo "  2. Set '输出路径' to: /tmp/test_no_template.xlsx"
echo "  3. Click '导出' button"
echo ""

echo "Test 3: Testing export with template..."
echo "Template: $TEMPLATE_PATH"
echo "Output: /tmp/test_with_template.xlsx"
echo "You can test this in the app by:"
echo "  1. Set '模板路径' to: $TEMPLATE_PATH"
echo "  2. Set '输出路径' to: /tmp/test_with_template.xlsx"
echo "  3. Click '导出' button"
echo ""

echo "=== Test Instructions ==="
echo ""
echo "To test the Excel export functionality:"
echo ""
echo "1. Launch the JiraMacTool application"
echo "2. Navigate to the 'Excel导出' tab"
echo "3. Test WITHOUT template:"
echo "   - Leave '模板路径' field empty"
echo "   - Set a date (e.g., 2026-04-30)"
echo "   - Click '导出' button"
echo "   - Check the output file"
echo ""
echo "4. Test WITH template:"
echo "   - Select the template file at: $TEMPLATE_PATH"
echo "   - Set a different output path"
echo "   - Click '导出' button"
echo "   - Compare the output with the template"
echo ""
echo "5. Verify the generated Excel files:"
echo "   - Open in Microsoft Excel or Numbers"
echo "   - Check if styles are applied correctly"
echo "   - Verify data is present"
echo ""

if [ -f "$TEMPLATE_PATH" ]; then
    echo "Template file size: $(ls -lh "$TEMPLATE_PATH" | awk '{print $5}')"
fi
