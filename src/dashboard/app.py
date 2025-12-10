import streamlit as st
from google.cloud import firestore
import pandas as pd
import plotly.express as px

# 1. Setup Page Config
st.set_page_config(
    page_title="Adaptive Threat Shadow",
    page_icon="🛡️",
    layout="wide",
    initial_sidebar_state="expanded"
)

# 2. Connect to Firestore
db = firestore.Client()

@st.cache_data(ttl=60)
def load_data():
    # Fetch latest 20 documents
    docs = db.collection("threats").order_by("timestamp", direction=firestore.Query.DESCENDING).limit(20).stream()
    data = []
    for doc in docs:
        d = doc.to_dict()
        row = {
            "ID": doc.id,
            "Timestamp": d.get("timestamp"),
            # Ensure Risk Score is captured safely
            "Risk Score": d.get("analysis", {}).get("risk_score", 0),
            "Summary": d.get("analysis", {}).get("summary", "N/A"),
            "Action": d.get("analysis", {}).get("action", "N/A"),
            "Source IP": d.get("original_data", {}).get("indicator", "N/A"),
            "Raw Data": d.get("original_data")
        }
        data.append(row)
    
    if not data:
        return pd.DataFrame()

    df = pd.DataFrame(data)
    
    # --- CRITICAL FIX: CLEAN DATA TYPES ---
    # Force "Risk Score" to numeric, turning errors (strings) into NaN
    df["Risk Score"] = pd.to_numeric(df["Risk Score"], errors='coerce')
    # Fill NaN values with 0 so the math doesn't break
    df["Risk Score"] = df["Risk Score"].fillna(0)
    
    return df

# 3. The Dashboard Layout
st.title("🛡️ Adaptive Threat Shadow // Command Center")
st.markdown("### *AI-Driven Real-Time Threat Intelligence*")

df = load_data()

if not df.empty:
    # --- TOP ROW: KPI METRICS ---
    col1, col2, col3, col4 = st.columns(4)
    
    # Calculate stats safely now that data is clean
    avg_risk = df["Risk Score"].mean()
    high_risk_count = df[df["Risk Score"] > 75].shape[0]
    
    col1.metric("Avg Risk Score", f"{avg_risk:.1f}", delta_color="inverse")
    col2.metric("Critical Threats", high_risk_count, delta_color="inverse")
    col3.metric("Total Events", len(df))
    col4.button("🔄 Refresh Data")

    # --- MIDDLE ROW: CHARTS ---
    st.divider()
    c1, c2 = st.columns([2, 1])
    
    with c1:
        st.subheader("Risk Velocity")
        if "Timestamp" in df.columns:
            fig = px.line(df, x="Timestamp", y="Risk Score", title="Risk Score Trend", markers=True)
            fig.update_layout(template="plotly_dark")
            st.plotly_chart(fig, use_container_width=True)
        
    with c2:
        st.subheader("Threat Distribution")
        fig2 = px.histogram(df, x="Risk Score", nbins=10, title="Risk Distribution", color_discrete_sequence=['#FF4B4B'])
        fig2.update_layout(template="plotly_dark")
        st.plotly_chart(fig2, use_container_width=True)

    # --- BOTTOM ROW: DATA TABLE ---
    st.divider()
    st.subheader("🛑 Latest Intercepts")
    st.dataframe(
        df[["Timestamp", "Risk Score", "Source IP", "Summary", "Action"]],
        use_container_width=True,
        hide_index=True
    )
    
    # --- DETAIL VIEW ---
    with st.expander("🕵️ View Latest AI Analysis Logic"):
        if not df.empty:
            st.json(df.iloc[0]["Raw Data"])
            st.write("**Gemini Analysis:**")
            st.write(df.iloc[0]["Summary"])
            st.write(f"**Recommended Action:** {df.iloc[0]['Action']}")

else:
    st.info("Waiting for threat data... Run the collector to generate events.")