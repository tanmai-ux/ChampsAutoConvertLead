# Production-only metadata for Lead auto-convert

Runs the Lead Auto Convert Request trigger (and so every conversion) as API User.
Usernames differ per org, so this is kept out of force-app.

Deploy after the main package, then in Setup > Platform Events > Lead Auto Convert Request >
Subscriptions > Manage, Suspend and Resume the trigger so the running user takes effect.

    cd deploy/production
    sf project deploy start -o <prod-alias> -d force-app

Check the username first: SELECT Username FROM User WHERE Name = 'API User' AND IsActive = true
