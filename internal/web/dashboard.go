package web

import (
	"net/http"
	"text/template"
)

// DashboardHandler handles the user dashboard page
func DashboardHandler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		// In a real implementation, we would:
		// 1. Check if user is authenticated
		// 2. Fetch user data
		// 3. Load template with data
		// 4. Render dashboard
		
		tmpl := template.Must(template.New("dashboard").Parse(`
<!DOCTYPE html>
<html>
<head>
    <title>Nugitea - Dashboard</title>
</head>
<body>
    <h1>Welcome to Nugitea Dashboard</h1>
    <p>You are logged in as an administrator.</p>
    <ul>
        <li><a href="/repos">Repositories</a></li>
        <li><a href="/users">Users</a></li>
        <li><a href="/issues">Issues</a></li>
        <li><a href="/pulls">Pull Requests</a></li>
    </ul>
</body>
</html>
`))
		
		if err := tmpl.Execute(w, nil); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
	}
}