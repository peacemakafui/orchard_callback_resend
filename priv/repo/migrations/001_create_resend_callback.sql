-- Create resend_callback table
CREATE TABLE IF NOT EXISTS resend_callback (
    id SERIAL PRIMARY KEY,
    entity_service_id INTEGER NOT NULL,
    exttrid VARCHAR(50),
    response TEXT NOT NULL,
    status VARCHAR(50) NOT NULL,
    http_status INTEGER,
    callback_req_id INTEGER NOT NULL,
    created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW() NOT NULL,
    updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW() NOT NULL,
    
    CONSTRAINT fk_callback_req
        FOREIGN KEY (callback_req_id)
        REFERENCES service_callback_push_req(id)
        ON DELETE CASCADE
);

-- Create indexes for better query performance
CREATE INDEX IF NOT EXISTS idx_resend_callback_entity_service_id ON resend_callback(entity_service_id);
CREATE INDEX IF NOT EXISTS idx_resend_callback_exttrid ON resend_callback(exttrid);
CREATE INDEX IF NOT EXISTS idx_resend_callback_callback_req_id ON resend_callback(callback_req_id);
CREATE INDEX IF NOT EXISTS idx_resend_callback_status ON resend_callback(status);
CREATE INDEX IF NOT EXISTS idx_resend_callback_created_at ON resend_callback(created_at);

-- Create a composite index for common query patterns
CREATE INDEX IF NOT EXISTS idx_resend_callback_service_processing ON resend_callback(entity_service_id, exttrid);