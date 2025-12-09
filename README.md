# ALY6980ZhiwenSun

📌 Multi-Agent Career Assistant (5-Agent System)

This project is a multi-agent career assistant built using FastAPI, Anthropic Claude, and SerpAPI. It processes a user’s resume and generates end-to-end career guidance using five fully independent AI agents, each handling a specific task.

🔧 Agents Included

Resume Agent Extracts text from PDF resumes and identifies the most likely job role.

Job-Match Agent Searches real, recent job listings using SerpAPI Google Jobs for any profession (tech, sales, nursing, teaching, labor, etc.).

Tailor-Agent Generates a customized, job-specific rewritten version of the resume.

Interview-Agent Produces tailored interview questions and preparation notes based on the selected job.

Project-Agent Suggests portfolio projects relevant to the job role for strengthening applications.

🚀 Key Features

Works for any job role, not just tech.

Provides real job listings, not hard-coded or fake ones.

Clean modular architecture → easy to deploy, extend, or convert into A2A agents.

Ready for local testing and cloud deployment (Linode/NEST/Nanda).
