package user

// User represents a user in the system
type User struct {
	ID       int64  `json:"id"`
	Name     string `json:"name"`
	Email    string `json:"email"`
	Password string `json:"password"`
	Admin    bool   `json:"admin"`
}

// Team represents a team of users
type Team struct {
	ID      int64  `json:"id"`
	Name    string `json:"name"`
	Members []int64 `json:"members"` // User IDs  
}