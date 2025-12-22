# QUICK START GUIDE - Workflow Assignment Module v2.0

## 🚀 Installation in 5 Minutes

### Step 1: Install Module (1 min)
```bash
# Copy to your Drupal installation
cp -r workflow_assignment /path/to/drupal/modules/custom/

# Enable module
drush en workflow_assignment -y

# Clear cache
drush cr
```

### Step 2: Configure Content Types (1 min)
1. Visit: `/admin/config/workflow/workflow-assignment`
2. Check the boxes for content types you want (e.g., Article, Page)
3. Leave vocabularies at defaults
4. Click "Save configuration"

### Step 3: Verify Installation (30 seconds)
1. Go to: `/admin/structure/taxonomy`
2. Confirm these vocabularies exist:
   - **Resource Locations** (for project resources)
   - **Destination Locations** (contains Public and Private)

### Step 4: Create Your First Workflow (2 mins)
1. Go to: `/admin/structure/workflow-list`
2. Click "Add Workflow List"
3. Fill in:
   ```
   Name: Marketing Campaign 2025
   Description: Q1 marketing workflow
   
   Assigned Users:
   ☑ John Smith
   ☑ Jane Doe
   
   Destination Locations:
   ☑ Public
   ```
4. Click "Save"

### Step 5: Test the Workflow Tab (30 seconds)
1. Create or edit any Article/Page
2. Assign your workflow in the "Workflow List" field
3. Save
4. **Click the "Workflow" tab** (new tab next to View/Edit)
5. See your workflow information displayed beautifully!

## ✨ You're Done!

Your workflow system is now set up with:
- ✅ Dedicated workflow tab on content
- ✅ Public and Private destination locations
- ✅ Easy workflow assignment
- ✅ Visual workflow display

## 🎯 What to Do Next

### Add More Destinations
Go to: `/admin/structure/taxonomy/manage/destination_locations/add`
- Add: "Internal Wiki"
- Add: "Customer Portal"
- Add: "Partner Site"

### Add Resource Locations
Go to: `/admin/structure/taxonomy/manage/resource_locations/add`
- Add: "Google Drive - Marketing"
- Add: "SharePoint - Projects"
- Add: "GitHub Repository"

### Create More Workflows
Go to: `/admin/structure/workflow-list/add`

Try different combinations:
- Content writing workflows
- Approval workflows
- Publication workflows
- Internal documentation workflows

## 🆘 Common Issues

### Tab Not Showing?
```bash
# Clear cache
drush cr

# Check permissions at /admin/people/permissions
# Ensure users have "View workflow list assignments"
```

### No Destinations in Dropdown?
```bash
# Run update hooks
drush updatedb -y
drush cr
```

### Field Missing on Content Type?
1. Go back to settings
2. Uncheck and re-check the content type
3. Save again

## 📚 Full Documentation

See `README.md` for complete documentation including:
- Advanced usage
- API documentation
- Theming guide
- Troubleshooting
- Use case examples

## 💡 Quick Tips

1. **Use Quick Edit** for fast workflow updates
   - Go to workflow list
   - Click "Quick Edit"
   - Change users/destinations
   - All content updates instantly

2. **Color-Coded Destinations**
   - Public = Blue
   - Private = Red
   - Add custom colors in CSS

3. **Workflow Tab is Key**
   - All workflow info in one place
   - No more searching through fields
   - Clean, professional display

## 🎉 Enjoy Your New Workflow System!

Questions? Check the README.md file for answers.

---
**Module Version:** 2.0  
**Installation Time:** ~5 minutes  
**Difficulty:** Easy  
**Drupal Version:** 10.x / 11.x
