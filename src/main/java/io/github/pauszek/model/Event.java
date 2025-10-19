package io.github.pauszek.model;

import lombok.Builder;
import lombok.Data;

import java.time.Instant;
import java.util.Map;

@Data
@Builder
public class Event {
    private String id;
    private String filename;
    private Instant timestamp;
    private String status;
    private Map<String, String> attributes;
}