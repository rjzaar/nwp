#!/bin/bash
# Quick diagnostic for Workflow Assignment module

echo "========================================"
echo "Workflow Assignment Quick Diagnostic"
echo "========================================"
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check 1: Module enabled
echo "1. Checking if module is enabled..."
if ddev drush pml | grep -q "workflow_assignment.*Enabled"; then
    echo -e "${GREEN}✓${NC} Module is enabled"
else
    echo -e "${RED}✗${NC} Module is NOT enabled"
    echo "   Run: ddev drush en workflow_assignment -y"
fi
echo ""

# Check 2: Configuration exists
echo "2. Checking configuration..."
if ddev drush config:get workflow_assignment.settings enabled_content_types > /dev/null 2>&1; then
    echo -e "${GREEN}✓${NC} Configuration exists"
    echo "   Enabled content types:"
    ddev drush config:get workflow_assignment.settings enabled_content_types
else
    echo -e "${RED}✗${NC} Configuration not found"
fi
echo ""

# Check 3: Basic page enabled
echo "3. Checking if 'page' content type is enabled..."
if ddev drush config:get workflow_assignment.settings enabled_content_types | grep -q "page"; then
    echo -e "${GREEN}✓${NC} Basic page (page) is enabled for workflows"
else
    echo -e "${YELLOW}⚠${NC} Basic page is NOT enabled"
    echo "   Go to: /admin/config/workflow/workflow-assignment"
    echo "   Check 'Basic page' and save"
fi
echo ""

# Check 4: Field exists
echo "4. Checking if workflow field exists on Basic page..."
if ddev drush field:list node.page 2>/dev/null | grep -q "field_workflow_list"; then
    echo -e "${GREEN}✓${NC} Field 'field_workflow_list' exists on Basic page"
else
    echo -e "${RED}✗${NC} Field 'field_workflow_list' NOT found on Basic page"
    echo "   Solution: Re-save settings at /admin/config/workflow/workflow-assignment"
fi
echo ""

# Check 5: Workflows exist
echo "5. Checking if any workflow lists exist..."
WORKFLOW_COUNT=$(ddev drush entity:list workflow_list 2>/dev/null | grep -c "workflow_list" || echo "0")
if [ "$WORKFLOW_COUNT" -gt 1 ]; then
    echo -e "${GREEN}✓${NC} Found workflow lists:"
    ddev drush entity:list workflow_list
else
    echo -e "${YELLOW}⚠${NC} No workflow lists found"
    echo "   Create one at: /admin/structure/workflow-list/add"
fi
echo ""

# Check 6: Destinations exist
echo "6. Checking destination locations..."
if ddev drush entity:list taxonomy_term --bundle=destination_locations 2>/dev/null | grep -q "Public\|Private"; then
    echo -e "${GREEN}✓${NC} Destination locations exist (Public/Private)"
else
    echo -e "${YELLOW}⚠${NC} Destination locations missing"
    echo "   Run: ddev drush updatedb -y"
fi
echo ""

# Check 7: Show test URL
echo "7. Key URLs to check:"
echo "   Settings:  /admin/config/workflow/workflow-assignment"
echo "   Workflows: /admin/structure/workflow-list"
echo "   Fields:    /admin/structure/types/manage/page/fields"
echo "   Form:      /admin/structure/types/manage/page/form-display"
echo ""

echo "========================================"
echo "Next Steps:"
echo "========================================"
echo "1. Clear cache: ddev drush cr"
echo "2. Visit: /admin/config/workflow/workflow-assignment"
echo "3. Ensure 'Basic page' is checked"
echo "4. Create a workflow at: /admin/structure/workflow-list/add"
echo "5. Edit a Basic page and look for 'Workflow List' field"
echo ""
