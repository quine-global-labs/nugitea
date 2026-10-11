package web

import (
	"fmt"
	"net/http"
	
	"nugitea/internal/auth"
	"nugitea/internal/user"
)

// Server represents the web server
type Server struct {
	userStore *user.Store
	auth      *auth.Authenticator
}

// NewServer creates a new web server
func NewServer() *Server {
	return &Server{
		userStore: user.NewStore(),
	}
}

// SetupRoutes sets up all HTTP routes
func (s *Server) SetupRoutes() http.Handler {
	mux := http.NewServeMux()
	
	// Public routes
	mux.HandleFunc("/", HomeHandler)
	mux.HandleFunc("/login", s.LoginHandler)
	mux.HandleFunc("/logout", s.LogoutHandler)
	
	// Protected routes
	mux.Handle("/dashboard", auth.RequireAuth(auth.MockAuthenticate)(s.DashboardHandler))
	mux.Handle("/users", auth.RequireAuth(auth.MockAuthenticate)(s.UsersHandler))
	
	return mux
}

// HomeHandler handles the home page
func HomeHandler(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintf(w, "<h1>Welcome to Nugitea</h1><p>This is a minimal Git server.</p>")
}

// LoginHandler handles login requests
func (s *Server) LoginHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method == "GET" {
		// Show login form
		fmt.Fprintf(w, `
<!DOCTYPE html>
<html>
<head>
    <title>Login - Nugitea</title>
</head>
<body>
    <h1>Login to Nugitea</h1>
    <form method="post" action="/login">
        <p>
            <label>Username:</label><br>
            <input type="text" name="username" required>
        </p>
        <p>
            <label>Password:</label><br>
            <input type="password" name="password" required>
        </p>
        <p>
            <button type="submit">Login</button>
        </p>
    </form>
</body>
</html>
`)
	} else {
		// Handle login form submission
		w.Header().Set("Location", "/dashboard")
		w.WriteHeader(http.StatusFound)
	}
}

// LogoutHandler handles logout requests
func (s *Server) LogoutHandler(w http.ResponseWriter, r *http.Request) {
	// In a real implementation, we would clear session/cookie
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

// DashboardHandler handles the dashboard page
func (s *Server) DashboardHandler(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintf(w, "<h1>Dashboard - Nugitea</h1><p>Welcome to your dashboard.</p>")
}

// UsersHandler handles the users page
func (s *Server) UsersHandler(w http.ResponseWriter, r *http.Request) {
	users := s.userStore.GetAllUsers()
	
	w.Header().Set("Content-Type", "text/html")
	fmt.Fprintf(w, "<h1>Users</h1><ul>")
	for _, user := range users {
		fmt.Fprintf(w, "<li>%s (%s)</li>", user.Name, user.Email)
	}
	fmt.Fprintf(w, "</ul>")
}

// Start starts the web server
func (s *Server) Start(addr string) error {
	handler := s.SetupRoutes()
	return http.ListenAndServe(addr, handler)
}